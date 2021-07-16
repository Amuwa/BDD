#pragma once

#include <numeric>
#include <stack>
#include <vector>
#include <tsl/robin_map.h>
#include "bdd_manager/bdd.h"
#include "ILP_input.h"
#include "avl_tree.hxx"

namespace LPMP {

// bit length needs to cover sum of all coefficients
using integer = long long int;

    struct lineq_bdd_node {

        lineq_bdd_node() {}
        lineq_bdd_node(integer lb, integer ub) : lb_(lb), ub_(ub)
        {}

        integer lb_ = 0;
        integer ub_ = 0; // initially also serves as cost of path from root

        lineq_bdd_node* zero_kid_ = nullptr;
        lineq_bdd_node* one_kid_ = nullptr;
        avl_node<lineq_bdd_node>* wrapper_ = nullptr; // wrapper node in the AVL tree
    };

    // Implementation of BDD construction from a linear inequality/equation (cf. Behle, 2007)
    class lineq_bdd {
        public:

            lineq_bdd() : topsink(0, std::numeric_limits<integer>::max()), 
                botsink(std::numeric_limits<integer>::min(), -1)
            {}
            lineq_bdd(lineq_bdd & other) = delete;

            void build_from_inequality(const std::vector<int>& nf, const ILP_input::inequality_type ineq_type);
            BDD::node_ref convert_to_lbdd(BDD::bdd_mgr & bdd_mgr_) const;

            template<typename COEFF_ITERATOR>
                static std::tuple< std::vector<int>, ILP_input::inequality_type >
                normal_form(COEFF_ITERATOR begin, COEFF_ITERATOR end, const ILP_input::inequality_type ineq_type, const int right_hand_side);

        private:

            bool build_bdd_node(lineq_bdd_node* &node_ptr, const integer path_cost, const unsigned int level, const ILP_input::inequality_type ineq_type);

            std::vector<char> inverted; // flags inverted variables
            std::vector<int> coefficients;
            std::vector<integer> rests;
            int rhs;

            lineq_bdd_node* root_node;
            std::vector<avl_tree<lineq_bdd_node>> levels;
            lineq_bdd_node topsink;
            lineq_bdd_node botsink;
    };


    template<typename COEFF_ITERATOR>
        std::tuple< std::vector<int>, ILP_input::inequality_type >
        lineq_bdd::normal_form(COEFF_ITERATOR begin, COEFF_ITERATOR end, const ILP_input::inequality_type ineq_type, const int right_hand_side)
        {
            assert(std::distance(begin,end) >= 1);
            int d = std::gcd(right_hand_side, *begin);
            for(auto it = begin+1; it != end; ++it)
                if(*it != 0)
                    d = std::gcd(d, *it);

            std::vector<int> c;
            c.reserve(std::distance(begin, end) + 1);
            c.push_back(right_hand_side/d);
            for(auto it = begin; it != end; ++it)
                c.push_back(*it/d);

            if(ineq_type == ILP_input::inequality_type::greater_equal)
                for(auto& x : c)
                    x *= -1.0;

            return {c, ineq_type != ILP_input::inequality_type::greater_equal ? ineq_type : ILP_input::inequality_type::smaller_equal};
        }

}
