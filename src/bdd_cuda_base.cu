#include "bdd_cuda_base.h"
#include "time_measure_util.h"
#include "cuda_utils.h"
#include <thrust/sort.h>
#include <thrust/for_each.h>
#include <thrust/gather.h>
#include <thrust/iterator/discard_iterator.h>

namespace LPMP {

    struct assign_new_indices_func {
        const int* new_indices;
        __host__ __device__ void operator()(int& idx)
        {
            if(idx >= 0) // non-terminal nodes.
                idx = new_indices[idx];
        }
    };

    struct not_equal_to
    {
        const int* values;
        const int val_to_search;
        __host__ __device__
        bool operator()(const int i) const
        {
            return values[i] != val_to_search;
        }
    };

    bdd_cuda_base::bdd_cuda_base(const BDD::bdd_collection& bdd_col)
    {
        initialize(bdd_col);
        thrust::device_vector<int> bdd_hop_dist_root, bdd_depth;
        std::tie(bdd_hop_dist_root, bdd_depth) = populate_bdd_nodes(bdd_col);
        reorder_bdd_nodes(bdd_hop_dist_root, bdd_depth);
        set_special_nodes_indices(bdd_hop_dist_root);
        compress_bdd_nodes_to_layer();
    }

    void bdd_cuda_base::initialize(const BDD::bdd_collection& bdd_col)
    {
        nr_vars_ = [&]() {
            size_t max_v=0;
            for(size_t bdd_nr=0; bdd_nr<bdd_col.nr_bdds(); ++bdd_nr)
                max_v = std::max(max_v, bdd_col.min_max_variables(bdd_nr)[1]);
            return max_v+1;
        }();
        nr_bdds_ = bdd_col.nr_bdds();
        std::vector<int> primal_variable_counts(nr_vars_, 0);
        std::vector<int> num_vars_per_bdd;
        for(size_t bdd_idx=0; bdd_idx < bdd_col.nr_bdds(); ++bdd_idx)
        {
            const std::vector<size_t> cur_bdd_variables = bdd_col.variables(bdd_idx);
            for (const auto& var : cur_bdd_variables)
                primal_variable_counts[var]++;
            num_vars_per_bdd.push_back(cur_bdd_variables.size());
            num_dual_variables_ += cur_bdd_variables.size();
            nr_bdd_nodes_ += bdd_col.nr_bdd_nodes(bdd_idx);
        }
        num_bdds_per_var_ = thrust::device_vector<int>(primal_variable_counts.begin(), primal_variable_counts.end());
        num_vars_per_bdd_ = thrust::device_vector<int>(num_vars_per_bdd.begin(), num_vars_per_bdd.end());
        // Initialize data per BDD node: 
        hi_cost_ = thrust::device_vector<float>(nr_bdd_nodes_, CUDART_INF_F);
        cost_from_root_ = thrust::device_vector<float>(nr_bdd_nodes_, CUDART_INF_F);
        cost_from_terminal_ = thrust::device_vector<float>(nr_bdd_nodes_, CUDART_INF_F);
        hi_path_cost_ = thrust::device_vector<float>(nr_bdd_nodes_, CUDART_INF_F);
        lo_path_cost_ = thrust::device_vector<float>(nr_bdd_nodes_, CUDART_INF_F);
    }

    std::tuple<thrust::device_vector<int>, thrust::device_vector<int>> bdd_cuda_base::populate_bdd_nodes(const BDD::bdd_collection& bdd_col)
    {
        std::vector<int> primal_variable_index;
        std::vector<int> lo_bdd_node_index;
        std::vector<int> hi_bdd_node_index;
        std::vector<int> bdd_index;
        std::vector<int> bdd_depth;
        // Store hop distance from root node, so that all nodes with same hop distance can be processed in parallel:
        std::vector<int> bdd_hop_dist_root;

        for(size_t bdd_idx=0; bdd_idx < bdd_col.nr_bdds(); ++bdd_idx)
        {
            assert(bdd_col.is_qbdd(bdd_idx));
            assert(bdd_col.is_reordered(bdd_idx));
            int cur_hop_dist = 0;
            const size_t storage_offset = bdd_col.offset(bdd_idx);
            size_t prev_var = bdd_col(bdd_idx, storage_offset).index;
            for(size_t bdd_node_idx=0; bdd_node_idx < bdd_col.nr_bdd_nodes(bdd_idx); ++bdd_node_idx)
            {
                const auto cur_instr = bdd_col(bdd_idx, bdd_node_idx + storage_offset);
                const size_t var = cur_instr.index;
                if(prev_var != var)
                {
                    assert(prev_var < var || cur_instr.is_terminal());
                    prev_var = var;
                    if(!cur_instr.is_topsink())
                        cur_hop_dist++; // both terminal nodes can have same hop distance.
                }
                if(!cur_instr.is_terminal())
                {
                    assert(bdd_node_idx < bdd_col.nr_bdd_nodes(bdd_idx) - 2); // only last two nodes can be terminal nodes. 
                    primal_variable_index.push_back(var);
                    lo_bdd_node_index.push_back(cur_instr.lo);
                    hi_bdd_node_index.push_back(cur_instr.hi);
                }
                else
                {
                    primal_variable_index.push_back(-1);
                    const int terminal_indicator = cur_instr.is_topsink() ? TOP_SINK_INDICATOR_CUDA: BOT_SINK_INDICATOR_CUDA;
                    lo_bdd_node_index.push_back(terminal_indicator);
                    hi_bdd_node_index.push_back(terminal_indicator);
                    assert(bdd_node_idx >= bdd_col.nr_bdd_nodes(bdd_idx) - 2);
                }
                bdd_hop_dist_root.push_back(cur_hop_dist);
                bdd_index.push_back(bdd_idx);
            }
            bdd_depth.insert(bdd_depth.end(), bdd_col.nr_bdd_nodes(bdd_idx), cur_hop_dist);
        }

        // copy to GPU
        primal_variable_index_ = thrust::device_vector<int>(primal_variable_index.begin(), primal_variable_index.end());
        bdd_index_ = thrust::device_vector<int>(bdd_index.begin(), bdd_index.end());
        lo_bdd_node_index_ = thrust::device_vector<int>(lo_bdd_node_index.begin(), lo_bdd_node_index.end());
        hi_bdd_node_index_ = thrust::device_vector<int>(hi_bdd_node_index.begin(), hi_bdd_node_index.end());
        assert(nr_vars_ == *thrust::max_element(primal_variable_index_.begin(), primal_variable_index_.end()) + 1);
        thrust::device_vector<int> bdd_hop_dist_dev(bdd_hop_dist_root.begin(), bdd_hop_dist_root.end());
        thrust::device_vector<int> bdd_depth_dev(bdd_depth.begin(), bdd_depth.end());
        return {bdd_hop_dist_dev, bdd_depth_dev};
    }

    void bdd_cuda_base::reorder_bdd_nodes(thrust::device_vector<int>& bdd_hop_dist_dev, thrust::device_vector<int>& bdd_depth_dev)
    {
        // Make nodes with same hop distance, BDD depth and bdd index contiguous in that order.
        thrust::device_vector<int> sorting_order(nr_bdd_nodes_);
        thrust::sequence(sorting_order.begin(), sorting_order.end());
        
        auto first_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_hop_dist_dev.begin(), bdd_depth_dev.begin(), bdd_index_.begin()));
        auto last_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_hop_dist_dev.end(), bdd_depth_dev.begin(), bdd_index_.end()));

        auto first_bdd_val = thrust::make_zip_iterator(thrust::make_tuple(primal_variable_index_.begin(), lo_bdd_node_index_.begin(), 
                                                                        hi_bdd_node_index_.begin(), sorting_order.begin()));
        thrust::sort_by_key(first_key, last_key, first_bdd_val);
        
        // Since the ordering is changed so lo, hi indices also need to be updated:
        thrust::device_vector<int> new_indices(sorting_order.size());
        thrust::scatter(thrust::make_counting_iterator<int>(0), thrust::make_counting_iterator<int>(0) + sorting_order.size(), 
                        sorting_order.begin(), new_indices.begin());
        assign_new_indices_func func({thrust::raw_pointer_cast(new_indices.data())});
        thrust::for_each(lo_bdd_node_index_.begin(), lo_bdd_node_index_.end(), func);
        thrust::for_each(hi_bdd_node_index_.begin(), hi_bdd_node_index_.end(), func);

        // Count number of BDD nodes per hop distance. Need for launching CUDA kernel with appropiate offset and threads:
        cum_nr_bdd_nodes_per_hop_dist_ = thrust::device_vector<int>(nr_bdd_nodes_);
        auto last_red = thrust::reduce_by_key(bdd_hop_dist_dev.begin(), bdd_hop_dist_dev.end(), thrust::make_constant_iterator<int>(1), 
                                                thrust::make_discard_iterator(), 
                                                cum_nr_bdd_nodes_per_hop_dist_.begin());
        cum_nr_bdd_nodes_per_hop_dist_.resize(thrust::distance(cum_nr_bdd_nodes_per_hop_dist_.begin(), last_red.second));

        // Convert to cumulative:
        thrust::inclusive_scan(cum_nr_bdd_nodes_per_hop_dist_.begin(), cum_nr_bdd_nodes_per_hop_dist_.end(), cum_nr_bdd_nodes_per_hop_dist_.begin());
    }

    void bdd_cuda_base::set_special_nodes_indices(const thrust::device_vector<int>& bdd_hop_dist_dev)
    {
        // Set indices of BDD nodes which are root, top, bot sinks.
        root_indices_ = thrust::device_vector<int>(nr_bdd_nodes_);
        thrust::sequence(root_indices_.begin(), root_indices_.end());
        auto last_root = thrust::remove_if(root_indices_.begin(), root_indices_.end(),
                                            not_equal_to({thrust::raw_pointer_cast(bdd_hop_dist_dev.data()), 0})); //TODO: This needs to be changed when multiple BDDs are in one row.
        root_indices_.resize(std::distance(root_indices_.begin(), last_root));

        bot_sink_indices_ = thrust::device_vector<int>(nr_bdd_nodes_);
        thrust::sequence(bot_sink_indices_.begin(), bot_sink_indices_.end());
        auto last_bot_sink = thrust::remove_if(bot_sink_indices_.begin(), bot_sink_indices_.end(),
                                            not_equal_to({thrust::raw_pointer_cast(lo_bdd_node_index_.data()), BOT_SINK_INDICATOR_CUDA}));
        bot_sink_indices_.resize(std::distance(bot_sink_indices_.begin(), last_bot_sink));

        top_sink_indices_ = thrust::device_vector<int>(nr_bdd_nodes_);
        thrust::sequence(top_sink_indices_.begin(), top_sink_indices_.end());
        auto last_top_sink = thrust::remove_if(top_sink_indices_.begin(), top_sink_indices_.end(),
                                            not_equal_to({thrust::raw_pointer_cast(lo_bdd_node_index_.data()), TOP_SINK_INDICATOR_CUDA}));
        top_sink_indices_.resize(std::distance(top_sink_indices_.begin(), last_top_sink));
    }

    // Removes redundant information in hi_costs, primal_index, bdd_index as it is duplicated across
    // multiple BDD nodes for each layer.
    void bdd_cuda_base::compress_bdd_nodes_to_layer()
    {
        thrust::device_vector<float> hi_cost_compressed(hi_cost_.size());
        thrust::device_vector<int> primal_index_compressed(primal_variable_index_.size()); 
        thrust::device_vector<int> bdd_index_compressed(bdd_index_.size());
        
        auto first_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_index_.begin(), primal_variable_index_.begin()));
        auto last_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_index_.end(), primal_variable_index_.end()));

        auto first_out_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_index_compressed.begin(), primal_index_compressed.begin()));

        // Compute number of BDD nodes in each layer:
        bdd_layer_width_ = thrust::device_vector<int>(nr_bdd_nodes_);
        auto new_end = thrust::reduce_by_key(first_key, last_key, thrust::make_constant_iterator<int>(1), first_out_key, bdd_layer_width_.begin());
        const int out_size = thrust::distance(first_out_key, new_end.first);

        // Assign bdd node to layer map:
        bdd_node_to_layer_map_ = thrust::device_vector<int>(out_size);
        thrust::sequence(bdd_node_to_layer_map_.begin(), bdd_node_to_layer_map_.end());
        bdd_node_to_layer_map_ = repeat_values(bdd_node_to_layer_map_, bdd_layer_width_);

        // Compress hi_costs_
        auto new_end_unique = thrust::unique_by_key_copy(first_key, last_key, hi_cost_.begin(), thrust::make_discard_iterator(), hi_cost_compressed.begin());
        assert(out_size == thrust::distance(hi_cost_compressed.begin(), new_end_unique.second));

        hi_cost_compressed.resize(out_size);
        primal_index_compressed.resize(out_size);
        bdd_index_compressed.resize(out_size);
        bdd_layer_width_.resize(out_size);

        thrust::swap(hi_cost_compressed, hi_cost_);
        thrust::swap(primal_index_compressed, primal_variable_index_);
        thrust::swap(bdd_index_compressed, bdd_index_);
    }

    void bdd_cuda_base::flush_forward_states()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        forward_state_valid_ = false;
        thrust::fill(cost_from_root_.begin(), cost_from_root_.end(), CUDART_INF_F);
        thrust::fill(hi_path_cost_.begin(), hi_path_cost_.end(), CUDART_INF_F);
        thrust::fill(lo_path_cost_.begin(), lo_path_cost_.end(), CUDART_INF_F);
    }

    void bdd_cuda_base::flush_backward_states()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        backward_state_valid_ = false;
        thrust::fill(cost_from_terminal_.begin(), cost_from_terminal_.end(), CUDART_INF_F);
        thrust::fill(hi_path_cost_.begin(), hi_path_cost_.end(), CUDART_INF_F);
        thrust::fill(lo_path_cost_.begin(), lo_path_cost_.end(), CUDART_INF_F);
    }

    struct set_var_cost_func {
        int var_index;
        float cost;
        __host__ __device__ void operator()(const thrust::tuple<int, float&> t) const
        {
            const int cur_var_index = thrust::get<0>(t);
            if(cur_var_index != var_index)
                return;
            float& hi_cost = thrust::get<1>(t);
            hi_cost = cost;
        }
    };

    void bdd_cuda_base::set_cost(const double c, const size_t var)
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        assert(var < nr_vars_);
        set_var_cost_func func({(int) var, (float) c / num_bdds_per_var_[var]});

        auto first = thrust::make_zip_iterator(thrust::make_tuple(primal_variable_index_.begin(), hi_cost_.begin()));
        auto last = thrust::make_zip_iterator(thrust::make_tuple(primal_variable_index_.end(), hi_cost_.end()));

        thrust::for_each(first, last, func);
    }

    struct set_vars_costs_func {
        int* var_counts;
        float* primal_costs;
        __host__ __device__ void operator()(const thrust::tuple<int, float&> t) const
        {
            const int cur_var_index = thrust::get<0>(t);
            float& hi_cost = thrust::get<1>(t);
            hi_cost = primal_costs[cur_var_index] / var_counts[cur_var_index];
        }
    };

    template<typename COST_ITERATOR> 
    void bdd_cuda_base::set_costs(COST_ITERATOR begin, COST_ITERATOR end)
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        assert(std::distance(begin, end) == nr_variables());
        thrust::device_vector<float> primal_costs(begin, end);
        
        set_vars_costs_func func({thrust::raw_pointer_cast(num_bdds_per_var_.data()), 
                                thrust::raw_pointer_cast(primal_costs.data())});
        auto first = thrust::make_zip_iterator(thrust::make_tuple(primal_variable_index_.begin(), hi_cost_.begin()));
        auto last = thrust::make_zip_iterator(thrust::make_tuple(primal_variable_index_.end(), hi_cost_.end()));

        thrust::for_each(first, last, func);
    }

    __global__ void forward_step(const int cur_num_bdd_nodes, const int start_offset,
                                const int* const __restrict__ lo_bdd_node_index, 
                                const int* const __restrict__ hi_bdd_node_index, 
                                const int* const __restrict__ bdd_node_to_layer_map, 
                                const float* const __restrict__ hi_cost,
                                float* __restrict__ cost_from_root)
    {
        const int start_index = blockIdx.x * blockDim.x + threadIdx.x;
        const int num_threads = blockDim.x * gridDim.x;
        for (int bdd_idx = start_index + start_offset; bdd_idx < cur_num_bdd_nodes + start_offset; bdd_idx += num_threads) 
        {
            const int next_lo_node = lo_bdd_node_index[bdd_idx];
            if (next_lo_node < 0) // will matter when one row contains multiple BDDs, otherwise the terminal nodes are at the end anyway.
                continue; // nothing needs to be done for terminal node.

            const int next_hi_node = hi_bdd_node_index[bdd_idx];
            assert(next_hi_node >= 0);

            const float cur_c_from_root = cost_from_root[bdd_idx];
            const int layer_idx = bdd_node_to_layer_map[bdd_idx];
            const float cur_hi_cost = hi_cost[layer_idx];

            // Uncoalesced writes:
            atomicMin(&cost_from_root[next_lo_node], cur_c_from_root); // TODO: Set cost_from_root to infinity before starting next iterations.
            atomicMin(&cost_from_root[next_hi_node], cur_c_from_root + cur_hi_cost);
        }
    }

    void bdd_cuda_base::forward_run()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        if (forward_state_valid_)
            return;

        // Set costs of root nodes to 0:
        thrust::scatter(thrust::make_constant_iterator<float>(0.0), 
                        thrust::make_constant_iterator<float>(0.0) + root_indices_.size(),
                        root_indices_.begin(),
                        cost_from_root_.begin());

        const int num_steps = cum_nr_bdd_nodes_per_hop_dist_.size() - 1;
        int num_nodes_processed = 0;
        for (int s = 0; s < num_steps; s++)
        {
            int threadCount = 256;
            int cur_num_bdd_nodes = cum_nr_bdd_nodes_per_hop_dist_[s] - num_nodes_processed;
            int blockCount = ceil(cur_num_bdd_nodes / (float) threadCount);
            std::cout<<"forward_run: "<<s<<", blockCount: "<<blockCount<<", cur_num_bdd_nodes: "<<cur_num_bdd_nodes<<"\n";
            forward_step<<<blockCount, threadCount>>>(cur_num_bdd_nodes, num_nodes_processed,
                                                    thrust::raw_pointer_cast(lo_bdd_node_index_.data()),
                                                    thrust::raw_pointer_cast(hi_bdd_node_index_.data()),
                                                    thrust::raw_pointer_cast(bdd_node_to_layer_map_.data()),
                                                    thrust::raw_pointer_cast(hi_cost_.data()),
                                                    thrust::raw_pointer_cast(cost_from_root_.data()));
            num_nodes_processed += cur_num_bdd_nodes;
        }
        forward_state_valid_ = true;
        // Set costs of bot sinks to infinity:
        // thrust::scatter(thrust::make_constant_iterator<float>(CUDART_INF_F), 
        //                 thrust::make_constant_iterator<float>(CUDART_INF_F) + bot_sink_indices_.size(),
        //                 bot_sink_indices_.begin(), 
        //                 cost_from_root_.begin());
    }

    __global__ void backward_step(const int cur_num_bdd_nodes, const int start_offset,
                                const int* const __restrict__ lo_bdd_node_index, 
                                const int* const __restrict__ hi_bdd_node_index, 
                                const int* const __restrict__ bdd_node_to_layer_map, 
                                const float* const __restrict__ hi_cost,
                                const float* __restrict__ cost_from_root, 
                                float* __restrict__ cost_from_terminal,
                                float* __restrict__ lo_path_cost, 
                                float* __restrict__ hi_path_cost)
    {
        const int start_index = blockIdx.x * blockDim.x + threadIdx.x;
        const int num_threads = blockDim.x * gridDim.x;
        for (int bdd_idx = start_index + start_offset; bdd_idx < cur_num_bdd_nodes + start_offset; bdd_idx += num_threads) 
        {
            const int lo_node = lo_bdd_node_index[bdd_idx];
            if (lo_node < 0)
                continue; // terminal node.
            const int hi_node = hi_bdd_node_index[bdd_idx];

            const bool is_lo_bot_sink = lo_bdd_node_index[lo_node] == BOT_SINK_INDICATOR_CUDA;
            const bool is_hi_bot_sink = lo_bdd_node_index[hi_node] == BOT_SINK_INDICATOR_CUDA;
            const int layer_idx = bdd_node_to_layer_map[bdd_idx];

            if (!is_lo_bot_sink && !is_hi_bot_sink)
            {
                const float next_lo_node_cost_terminal = cost_from_terminal[lo_node];
                const float next_hi_node_cost_terminal = cost_from_terminal[hi_node];

                const float cur_hi_cost_from_terminal = next_hi_node_cost_terminal + hi_cost[layer_idx];
                cost_from_terminal[bdd_idx] = min(cur_hi_cost_from_terminal, next_lo_node_cost_terminal);

                const float cur_cost_from_root = cost_from_root[bdd_idx];
                hi_path_cost[bdd_idx] = cur_cost_from_root + cur_hi_cost_from_terminal;
                lo_path_cost[bdd_idx] = cur_cost_from_root + next_lo_node_cost_terminal;
            }

            else if(!is_lo_bot_sink)
            {
                const float next_lo_node_cost_terminal = cost_from_terminal[lo_node];
                cost_from_terminal[bdd_idx] = next_lo_node_cost_terminal;
                lo_path_cost[bdd_idx] = cost_from_root[bdd_idx] + next_lo_node_cost_terminal;
            }
            else if(!is_hi_bot_sink)
            {
                const float cur_hi_cost_from_terminal = cost_from_terminal[hi_node] + hi_cost[layer_idx];
                cost_from_terminal[bdd_idx] = cur_hi_cost_from_terminal;
                hi_path_cost[bdd_idx] = cost_from_root[bdd_idx] + cur_hi_cost_from_terminal;
            }
            __syncthreads();
        }
    }

    void bdd_cuda_base::backward_run()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        if (backward_state_valid_)
            return;

        const int num_steps = cum_nr_bdd_nodes_per_hop_dist_.size() - 2;

        // Set costs of top sinks to 0:
        thrust::scatter(thrust::make_constant_iterator<float>(0.0), 
                        thrust::make_constant_iterator<float>(0.0) + top_sink_indices_.size(),
                        top_sink_indices_.begin(), 
                        cost_from_terminal_.begin());

        for (int s = num_steps; s >= 0; s--)
        {
            int threadCount = 256;
            int start_offset = 0;
            if(s > 0)
                start_offset = cum_nr_bdd_nodes_per_hop_dist_[s - 1];

            int cur_num_bdd_nodes = cum_nr_bdd_nodes_per_hop_dist_[s] - start_offset;
            int blockCount = ceil(cur_num_bdd_nodes / (float) threadCount);
            std::cout<<"backward_run: "<<s<<", blockCount: "<<blockCount<<"\n";
            backward_step<<<blockCount, threadCount>>>(cur_num_bdd_nodes, start_offset,
                                                    thrust::raw_pointer_cast(lo_bdd_node_index_.data()),
                                                    thrust::raw_pointer_cast(hi_bdd_node_index_.data()),
                                                    thrust::raw_pointer_cast(bdd_node_to_layer_map_.data()),
                                                    thrust::raw_pointer_cast(hi_cost_.data()),
                                                    thrust::raw_pointer_cast(cost_from_root_.data()),
                                                    thrust::raw_pointer_cast(cost_from_terminal_.data()),
                                                    thrust::raw_pointer_cast(lo_path_cost_.data()),
                                                    thrust::raw_pointer_cast(hi_path_cost_.data()));
        }
        backward_state_valid_ = true;
    }

    struct tuple_min
    {
        __host__ __device__
        thrust::tuple<float, float> operator()(const thrust::tuple<float, float>& t0, const thrust::tuple<float, float>& t1)
        {
            return thrust::make_tuple(min(thrust::get<0>(t0), thrust::get<0>(t1)), min(thrust::get<1>(t0), thrust::get<1>(t1)));
        }
    };

    // Compute min-marginals by reduction.
    // TODO: Warp aggregation or not (?) https://on-demand.gputechconf.com/gtc/2017/presentation/s7622-Kyrylo-perelygin-robust-and-scalable-cuda.pdf
    std::tuple<thrust::device_vector<float>, thrust::device_vector<float>> bdd_cuda_base::min_marginals_cuda()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        forward_run();
        backward_run();

        auto first_val = thrust::make_zip_iterator(thrust::make_tuple(lo_path_cost_.begin(), hi_path_cost_.begin()));

        thrust::device_vector<float> min_marginals_lo(hi_cost_.size());
        thrust::device_vector<float> min_marginals_hi(hi_cost_.size());
        auto first_out_val = thrust::make_zip_iterator(thrust::make_tuple(min_marginals_lo.begin(), min_marginals_hi.begin()));

        thrust::equal_to<int> binary_pred;

        auto new_end = thrust::reduce_by_key(bdd_node_to_layer_map_.begin(), bdd_node_to_layer_map_.end(), first_val, thrust::make_discard_iterator(), first_out_val, binary_pred, tuple_min());
        const int out_size = thrust::distance(first_out_val, new_end.second);
        assert(out_size == hi_cost_.size());

        return {min_marginals_lo, min_marginals_hi};
    }

    std::vector<std::vector<std::array<float, 2>>> bdd_cuda_base::min_marginals()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        thrust::device_vector<float> mm_0, mm_1;

        std::tie(mm_0, mm_1) = min_marginals_cuda();

        // sort the min-marginals per bdd_index, primal_index:
        thrust::device_vector<int> bdd_index_sorted = bdd_index_;
        thrust::device_vector<int> primal_variable_index_sorted = primal_variable_index_;
        auto first_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_index_sorted.begin(), primal_variable_index_sorted.begin()));
        auto last_key = thrust::make_zip_iterator(thrust::make_tuple(bdd_index_sorted.end(), primal_variable_index_sorted.end()));

        auto first_val = thrust::make_zip_iterator(thrust::make_tuple(mm_0.begin(), mm_1.begin()));

        thrust::sort_by_key(first_key, last_key, first_val);

        std::vector<int> num_vars_per_bdd(num_vars_per_bdd_.size());
        thrust::copy(num_vars_per_bdd_.begin(), num_vars_per_bdd_.end(), num_vars_per_bdd.begin());

        std::vector<int> h_mm_primal_index(primal_variable_index_sorted.size());
        thrust::copy(primal_variable_index_sorted.begin(), primal_variable_index_sorted.end(), h_mm_primal_index.begin());

        std::vector<int> h_mm_bdd_index(bdd_index_sorted.size());
        thrust::copy(bdd_index_sorted.begin(), bdd_index_sorted.end(), h_mm_bdd_index.begin());

        std::vector<float> h_mm_0(mm_0.size());
        thrust::copy(mm_0.begin(), mm_0.end(), h_mm_0.begin());

        std::vector<float> h_mm_1(mm_1.size());
        thrust::copy(mm_1.begin(), mm_1.end(), h_mm_1.begin());

        std::vector<std::vector<std::array<float,2>>> min_margs(nr_bdds());

        int idx_1d = 1; // ignore terminal nodes.
        for(int bdd_idx=0; bdd_idx < nr_bdds(); ++bdd_idx)
        {
            for(int var = 0; var < num_vars_per_bdd[bdd_idx]; var++, idx_1d++)
            {
                assert(h_mm_primal_index[idx_1d] >= 0); // Should ignore terminal nodes.
                std::array<float,2> mm = {h_mm_0[idx_1d], h_mm_1[idx_1d]};
                min_margs[bdd_idx].push_back(mm);
            }
            idx_1d += 1; // 2 terminal nodes per bdd (but are reduced to one during min-marginal computation).
        }

        return min_margs;
    }

    struct return_top_sink_costs
    {
        __host__ __device__ double operator()(const thrust::tuple<int, float>& t) const
        {
            const int index = thrust::get<0>(t);
            if (index != TOP_SINK_INDICATOR_CUDA)
                return 0.0;
            return thrust::get<1>(t);
        }
    };

    void bdd_cuda_base::update_costs(const thrust::device_vector<float>& update_vec)
    {
        thrust::transform(hi_cost_.begin(), hi_cost_.end(), update_vec.begin(), hi_cost_.begin(), thrust::plus<float>());
        flush_forward_states();
        flush_backward_states();
    }

    double bdd_cuda_base::lower_bound()
    {
        MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME
        forward_run();

        // Gather all BDD nodes corresponding to top_sink (i.e. lo_bdd_node_index_ == TOP_SINK_INDICATOR_CUDA) and sum their costs_from_root
        auto first = thrust::make_zip_iterator(thrust::make_tuple(lo_bdd_node_index_.begin(), cost_from_root_.begin()));
        auto last = thrust::make_zip_iterator(thrust::make_tuple(lo_bdd_node_index_.end(), cost_from_root_.end()));

        return thrust::transform_reduce(first, last, return_top_sink_costs(), 0.0, thrust::plus<double>());
    }
}
