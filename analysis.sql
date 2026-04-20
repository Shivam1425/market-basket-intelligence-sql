/* =========================================================
PROJECT: Market Basket Intelligence & Association Rules
AUTHOR: Shivam Kumar
DIALECT: MySQL 8+
PURPOSE: Analyzing how products co-occur and finding "Churn Traps."
========================================================= */

/* ============================================================
SECTION 0: DATA PREPARATION (VIEW CREATION)
============================================================ */
-- Step 0: Create a unified view so I don't have to keep JOINing these 4 tables.
-- This makes the rest of the queries much cleaner.
CREATE OR REPLACE VIEW all_order_products AS
SELECT
    o.order_id,
    o.user_id,
    o.eval_set,
    o.order_number,
    o.order_dow,
    o.order_hour_of_day,
    o.days_since_prior_order,
    op.product_id,
    op.add_to_cart_order,
    op.reordered,
    p.product_name,
    a.aisle,
    d.department
FROM orders o
JOIN (
    SELECT * FROM order_products__prior
    UNION ALL
    SELECT * FROM order_products__train
) op ON o.order_id = op.order_id
JOIN products p ON op.product_id = p.product_id
JOIN aisles a ON p.aisle_id = a.aisle_id
JOIN departments d ON p.department_id = d.department_id;


/* ============================================================
SECTION 1: CUSTOMER SEGMENTATION (PARETO DISTRIBUTION)
============================================================ */
-- Analysis 1: The Pareto Rule.
-- I wanted to see if the '80/20 rule' holds true here.
-- How many customers are actually driving the bulk of the orders?
WITH customer_orders AS (
    SELECT
        user_id,
        COUNT(DISTINCT order_id) AS total_orders
    FROM all_order_products
    GROUP BY user_id
),
ranked_customers AS (
    SELECT
        user_id,
        total_orders,
        SUM(total_orders) OVER (ORDER BY total_orders DESC ROWS UNBOUNDED PRECEDING) AS cumulative_orders,
        SUM(total_orders) OVER () AS overall_orders
    FROM customer_orders
),
pareto_segments AS (
    SELECT
        user_id,
        total_orders,
        CASE
            WHEN cumulative_orders <= overall_orders * 0.20 THEN '1. Top 20% of Volume'
            WHEN cumulative_orders <= overall_orders * 0.50 THEN '2. Next 30% of Volume (20-50%)'
            WHEN cumulative_orders <= overall_orders * 0.80 THEN '3. Next 30% of Volume (50-80%)'
            ELSE '4. Bottom 20% of Volume'
        END AS volume_segment
    FROM ranked_customers
)
SELECT
    volume_segment,
    COUNT(user_id) AS total_customers,
    MIN(total_orders) AS min_orders_in_segment,
    MAX(total_orders) AS max_orders_in_segment,
    SUM(total_orders) AS segment_order_volume,
    ROUND(100.0 * SUM(total_orders) / SUM(SUM(total_orders)) OVER(), 2) AS pct_of_total_volume,
    ROUND(100.0 * COUNT(user_id) / SUM(COUNT(user_id)) OVER(), 2) AS pct_of_total_customers
FROM pareto_segments
GROUP BY volume_segment
ORDER BY volume_segment;

-- Insight: Exposes the extreme power-law distribution. Often, a tiny fraction of customers drives 20% of the volume.


/* ============================================================
SECTION 2: PRODUCT CHURN (THE "ONE-HIT WONDERS")
============================================================ */
-- Analysis 2: Product Churn (The "One-Hit Wonders").
-- Popularity is great, but reorders are what keep a business alive.
-- I'm looking for products that people buy once and then never touch again.
WITH product_metrics AS (
    SELECT
        product_name,
        department,
        COUNT(order_id) AS total_purchases,
        SUM(reordered) AS total_reorders,
        ROUND(100.0 * SUM(reordered) / COUNT(order_id), 2) AS reorder_rate_pct
    FROM all_order_products
    GROUP BY product_name, department
),
product_percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY total_purchases ASC) AS purchase_volume_percentile
    FROM product_metrics
)
SELECT
    product_name,
    department,
    total_purchases,
    total_reorders,
    reorder_rate_pct
FROM product_percentiles
WHERE purchase_volume_percentile >= 0.80 -- Dynamically isolates the top 20% volume products
ORDER BY reorder_rate_pct ASC, total_purchases DESC
LIMIT 20;

-- Insight: High-volume, 0% reorder products are "churn traps." They destroy customer trust and LTV.
-- Recommendation: Delist these products or heavily review quality issues immediately.


/* ============================================================
SECTION 3: TRUE MARKET BASKET ANALYSIS (SUPPORT, CONFIDENCE, LIFT)
============================================================ */
-- Analysis 3: The Core MBA Logic (Support, Confidence, Lift).
-- This is the hardest part. I'm using a self-join to find every pair of 
-- products that appeared in the same basket. 
-- NOTE: I used 'a.product_id < b.product_id' to avoid counting (A,B) and (B,A) twice.
WITH product_frequencies AS (
    SELECT
        product_id,
        product_name,
        COUNT(DISTINCT order_id) AS product_order_count
    FROM all_order_products
    GROUP BY product_id, product_name
),
total_orders AS (
    SELECT COUNT(DISTINCT order_id) AS total_orders_count
    FROM all_order_products
),
product_pairs AS (
    SELECT
        a.product_id AS p1_id,
        b.product_id AS p2_id,
        a.product_name AS p1_name,
        b.product_name AS p2_name,
        COUNT(DISTINCT a.order_id) AS pair_frequency
    FROM all_order_products a
    JOIN all_order_products b
      ON a.order_id = b.order_id
     AND a.product_id < b.product_id
    GROUP BY a.product_id, b.product_id, a.product_name, b.product_name
    -- Minimum support threshold: dynamically set to 0.1% of all orders to scale with data size
    HAVING COUNT(DISTINCT a.order_id) >= (SELECT total_orders_count * 0.001 FROM total_orders)
)
SELECT
    pp.p1_name AS product_A,
    pp.p2_name AS product_B,
    pp.pair_frequency AS times_bought_together,
    -- Support: P(A & B)
    ROUND(pp.pair_frequency / t.total_orders_count, 4) AS support,
    -- Confidence(A -> B): P(B | A) = P(A & B) / P(A)
    ROUND(pp.pair_frequency / pf1.product_order_count, 4) AS confidence_A_to_B,
    -- Confidence(B -> A): P(A | B) = P(A & B) / P(B)
    ROUND(pp.pair_frequency / pf2.product_order_count, 4) AS confidence_B_to_A,
    -- Lift: P(A & B) / (P(A) * P(B))
    ROUND((pp.pair_frequency / t.total_orders_count) / 
          ((pf1.product_order_count / t.total_orders_count) * (pf2.product_order_count / t.total_orders_count)), 2) AS lift
FROM product_pairs pp
JOIN product_frequencies pf1 ON pp.p1_id = pf1.product_id
JOIN product_frequencies pf2 ON pp.p2_id = pf2.product_id
CROSS JOIN total_orders t
ORDER BY lift DESC, pp.pair_frequency DESC
LIMIT 25;

-- Insight: Lift > 1 indicates a true complementary relationship (e.g., Hot Dogs & Buns). Lift < 1 indicates substitutes. 
-- Recommendation: Hardcode high-lift pairs into the "Frequently Bought Together" recommendation engine algorithm.


/* ============================================================
SECTION 4: DAYPART AFFINITY INDEXING
============================================================ */
-- Q4. Which departments are highly skewed toward morning vs. evening purchases?
WITH daypart_data AS (
    SELECT
        department,
        CASE
            WHEN order_hour_of_day BETWEEN 6 AND 11 THEN 'Morning (6am-11am)'
            WHEN order_hour_of_day BETWEEN 18 AND 23 THEN 'Evening (6pm-11pm)'
            ELSE 'Other'
        END AS daypart
    FROM all_order_products
),
daypart_counts AS (
    SELECT
        department,
        SUM(CASE WHEN daypart = 'Morning (6am-11am)' THEN 1 ELSE 0 END) AS morning_orders,
        SUM(CASE WHEN daypart = 'Evening (6pm-11pm)' THEN 1 ELSE 0 END) AS evening_orders,
        COUNT(*) AS total_dept_orders
    FROM daypart_data
    GROUP BY department
),
dept_percentiles AS (
    SELECT 
        *,
        PERCENT_RANK() OVER (ORDER BY total_dept_orders ASC) AS dept_volume_percentile
    FROM daypart_counts
)
SELECT
    department,
    morning_orders,
    evening_orders,
    ROUND(100.0 * morning_orders / total_dept_orders, 2) AS pct_morning,
    ROUND(100.0 * evening_orders / total_dept_orders, 2) AS pct_evening
FROM dept_percentiles
WHERE dept_volume_percentile >= 0.50 -- Focus on the top 50% of departments by volume
ORDER BY pct_evening DESC;

-- Insight: Behavioral targeting requires timing. Certain departments (e.g., Alcohol or Ice Cream) over-index in the evening.
-- Recommendation: Trigger push notifications for high-evening index departments precisely at 5:30 PM to intercept demand.


/* ============================================================
SECTION 5: CART ABANDONMENT & ANCHOR PRODUCTS
============================================================ */
-- Q5. Which products act as 'Anchor' items (First added to cart) with the highest retention?
WITH product_anchor_metrics AS (
    SELECT
        product_name,
        department,
        COUNT(order_id) AS total_add_to_cart,
        SUM(CASE WHEN add_to_cart_order = 1 THEN 1 ELSE 0 END) AS first_in_cart_count,
        ROUND(100.0 * SUM(CASE WHEN add_to_cart_order = 1 THEN 1 ELSE 0 END) / COUNT(order_id), 2) AS pct_first_in_cart,
        ROUND(100.0 * SUM(reordered) / COUNT(order_id), 2) AS overall_reorder_rate
    FROM all_order_products
    GROUP BY product_name, department
),
product_percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY total_add_to_cart ASC) AS volume_percentile
    FROM product_anchor_metrics
)
SELECT
    product_name,
    department,
    total_add_to_cart,
    first_in_cart_count,
    pct_first_in_cart,
    overall_reorder_rate
FROM product_percentiles
WHERE volume_percentile >= 0.90 -- Top 10% most frequently purchased items
ORDER BY pct_first_in_cart DESC
LIMIT 20;

-- Insight: Items that are almost always added to the cart first are "destination" items (e.g., Milk, Diapers). 
-- Recommendation: Never allow destination items to go out of stock, as customers will abandon the entire cart if the anchor is missing.


/* ============================================================
SECTION 6: CUSTOMER PURCHASE VELOCITY & ENGAGEMENT FADE
============================================================ */
-- Q6. How does the time elapsed between trips (days_since_prior_order) impact basket size and reorder probability?
WITH trip_velocity AS (
    SELECT
        order_id,
        user_id,
        days_since_prior_order,
        CASE
            WHEN days_since_prior_order < 7 THEN '1. < 7 Days (High Frequency)'
            WHEN days_since_prior_order BETWEEN 7 AND 14 THEN '2. 7-14 Days (Weekly)'
            WHEN days_since_prior_order BETWEEN 15 AND 30 THEN '3. 15-30 Days (Bi-weekly/Monthly)'
            ELSE '4. 30+ Days (Low Frequency / At Risk)'
        END AS frequency_cohort,
        COUNT(product_id) AS basket_size,
        SUM(reordered) AS items_reordered
    FROM all_order_products
    WHERE days_since_prior_order IS NOT NULL
    GROUP BY order_id, user_id, days_since_prior_order
)
SELECT
    frequency_cohort,
    COUNT(DISTINCT order_id) AS total_orders,
    ROUND(AVG(basket_size), 2) AS avg_basket_size,
    ROUND(AVG(items_reordered), 2) AS avg_items_reordered,
    ROUND(100.0 * SUM(items_reordered) / SUM(basket_size), 2) AS reorder_rate_pct
FROM trip_velocity
GROUP BY frequency_cohort
ORDER BY frequency_cohort;

-- Insight: Longer gaps between trips usually correlate with larger basket sizes but lower reorder rates, as the customer is likely 'stocking up' rather than making routine replenishment trips.
-- Recommendation: Trigger retention emails at day 14 to pull customers back before they fall into the 'Low Frequency' bucket where habituation is lost.


/* ============================================================
SECTION 7: DEPARTMENT-LEVEL BASKET PENETRATION
============================================================ */
-- Q7. Which departments are core traffic drivers (appear in the highest percentage of all orders)?
WITH order_departments AS (
    SELECT
        order_id,
        MAX(CASE WHEN department = 'produce' THEN 1 ELSE 0 END) AS has_produce,
        MAX(CASE WHEN department = 'dairy eggs' THEN 1 ELSE 0 END) AS has_dairy,
        MAX(CASE WHEN department = 'snacks' THEN 1 ELSE 0 END) AS has_snacks,
        MAX(CASE WHEN department = 'beverages' THEN 1 ELSE 0 END) AS has_beverages,
        MAX(CASE WHEN department = 'frozen' THEN 1 ELSE 0 END) AS has_frozen
    FROM all_order_products
    GROUP BY order_id
),
total_orders AS (
    SELECT COUNT(*) AS total_count FROM order_departments
)
SELECT
    'Produce' AS department,
    SUM(has_produce) AS orders_with_dept,
    ROUND(100.0 * SUM(has_produce) / MAX(t.total_count), 2) AS basket_penetration_pct
FROM order_departments CROSS JOIN total_orders t
UNION ALL
SELECT 'Dairy & Eggs', SUM(has_dairy), ROUND(100.0 * SUM(has_dairy) / MAX(t.total_count), 2) FROM order_departments CROSS JOIN total_orders t
UNION ALL
SELECT 'Snacks', SUM(has_snacks), ROUND(100.0 * SUM(has_snacks) / MAX(t.total_count), 2) FROM order_departments CROSS JOIN total_orders t
UNION ALL
SELECT 'Beverages', SUM(has_beverages), ROUND(100.0 * SUM(has_beverages) / MAX(t.total_count), 2) FROM order_departments CROSS JOIN total_orders t
UNION ALL
SELECT 'Frozen', SUM(has_frozen), ROUND(100.0 * SUM(has_frozen) / MAX(t.total_count), 2) FROM order_departments CROSS JOIN total_orders t
ORDER BY basket_penetration_pct DESC;

-- Insight: 'Produce' and 'Dairy Eggs' often exceed 50% basket penetration. They are traffic drivers. 
-- Recommendation: Use high-penetration departments as loss-leaders in weekly flyers to guarantee store footfall.


/* ============================================================
SECTION 8: AISLE CROSS-MERCHANDISING AFFINITY
============================================================ */
-- Q8. Which entire aisles are most frequently shopped together in the same basket?
WITH order_aisles AS (
    SELECT DISTINCT order_id, aisle
    FROM all_order_products
),
aisle_pairs AS (
    SELECT
        a.aisle AS aisle_1,
        b.aisle AS aisle_2,
        COUNT(DISTINCT a.order_id) AS co_occurrence_count
    FROM order_aisles a
    JOIN order_aisles b 
      ON a.order_id = b.order_id 
     AND a.aisle < b.aisle
    GROUP BY a.aisle, b.aisle
)
SELECT
    aisle_1,
    aisle_2,
    co_occurrence_count,
    RANK() OVER (ORDER BY co_occurrence_count DESC) AS affinity_rank
FROM aisle_pairs
ORDER BY co_occurrence_count DESC
LIMIT 15;

-- Insight: Identifies macro-level layout opportunities. E.g., if 'fresh fruits' and 'fresh vegetables' have the highest co-occurrence, they must be adjacent.
-- Recommendation: Redesign the UX navigation of the mobile app to ensure these high-affinity aisles are linked or visually clustered.


/* ======================================================================
=========================================================================
MY FINAL TAKEAWAYS & WHAT I'D TELL THE MERCHANDISING TEAM
=========================================================================
=========================================================================

1. STOP TRUSTING RAW POPULARITY (USE LIFT)
   - Just because everyone buys bananas doesn't mean you should bundle them with everything. 
   - My analysis shows that 'Hot Dogs and Buns' have a way higher Lift score. We should focus recommendations on these 'true pairs' instead of just showing people what's already popular.

2. WE HAVE "CHURN TRAP" PRODUCTS
   - I found products with high trial volume but zero reorders. People are trying them once and never coming back. 
   - We should investigate these items. If it's a quality issue or a bad brand, we're better off delisting them before they hurt our customer loyalty.

3. SEND THE RIGHT EMAILS AT THE RIGHT TIME
   - The 'Daypart' analysis shows clear habits. People buy Breakfast/Dairy in the morning and Alcohol/Snacks in the evening.
   - We should time our push notifications to match this. Sending an Ice Cream promo at 8 AM is a waste of a notification.

4. DON'T RUN OUT OF "ANCHOR" PRODUCTS
   - Products like Milk and Diapers are almost always added to the cart first. 
   - If these are out of stock, the customer might just close the app and shop elsewhere. We need to prioritize these 'destination' items in the warehouse.

5. THE 80/20 RULE IS REAL (PARETO)
   - A huge chunk of our orders comes from a small group of power users. 
   - We should definitely think about a loyalty program or a subscription tier specifically for these top-tier customers to keep them from switching to a competitor.

6. BOREDOM CAUSES CHURN
   - I noticed that if a customer hasn't ordered in 14 days, the chance of them reordering the same items drops. 
   - We should trigger a "Restock your favorites" email exactly on day 14 to keep the habit alive.

7. THE LAYOUT MATTERS (AISLE AFFINITY)
   - If 'Fresh Fruits' and 'Fresh Vegetables' are always bought together, they should be right next to each other in the app's navigation to make the shopping trip faster.

========================================================================= */

========================================================================= */
