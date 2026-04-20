# Market Basket Intelligence & Association Rules

**Author:** Shivam Kumar  
**SQL Dialect:** MySQL 8.0+  
**Dataset:** [Instacart Market Basket Analysis (Kaggle)](https://www.kaggle.com/code/brightboakye/market-basket-analysis-instacart)

## What This Project Is About

Most "product analysis" in SQL portfolios is just `SELECT product, COUNT(*) ORDER BY DESC LIMIT 10`. That tells you what's popular, but it's pretty basic. 

I wanted to go deeper. I wrote the Association Rule Mining math (Support, Confidence, and Lift) directly in SQL to find out which products people *actually* buy together. I also looked for "Churn Traps" (items people try once but never reorder) and "Daypart Affinity" to see how shopping habits change from morning to night.

## What I Was Trying to Answer

1. Which product pairs have the highest Lift? High Lift means customers buy them together more than random chance would predict — that's a real complementary relationship worth acting on.
2. Which product departments are heavy morning purchases vs evening purchases? Knowing this lets you time push notifications by department.
3. Which items do customers add to their cart first? Items added first are "destination items" — a stockout on them likely causes full cart abandonment.
4. How concentrated is spend across customer deciles?

## What I Found

- **Frozen** and **Dry Goods Pasta** showed the highest evening affinity index. This suggests evening shoppers are focused on dinner prep and convenient meals.
- **Organic Low Fat Milk** and **Drinking Water** were the strongest "Anchor" products, being added to the cart first in over 40% of their orders.
- The top decile of customers generates a disproportionate share of revenue — the Power Law holds even in grocery data.

**Sample output — Top Product Pair Lift Scores (Section 3):**
![Association Rules](assets/association_rules.png)

### **Daypart Affinity & Behavior**
Certain departments (like Frozen and Dry Goods) significantly over-index in evening orders compared to the morning rush.
![Daypart Affinity](assets/daypart_affinity.png)

### **Anchor Product Identification**
Items like **Organic Low Fat Milk** and **Drinking Water** are almost always added to the cart first, acting as "destination" items that anchor the trip.
![Anchor Products](assets/anchor_products.png)

Bananas and Organic Bananas have high absolute co-occurrence but a Lift of only 1.43 — people buy them together, but mainly because both are very popular individually. Hot Dogs and Hot Dog Buns have much lower raw counts but a Lift of 3.42, meaning customers buy them together 3.42x more than chance would predict. That's the pair worth acting on.

## How the Association Rules Work (No Jargon)

The core of this analysis is a self-join on the basket items table:

```sql
JOIN basket_items b 
  ON a.basket_id = b.basket_id 
 AND a.product_id < b.product_id
```

The `basket_id` condition finds every basket where both products appear. The `a.product_id < b.product_id` condition is important — it prevents (Hot Dogs, Buns) and (Buns, Hot Dogs) from being counted as two separate pairs. Without that condition, every pair shows up twice and all the math is wrong.

From there:
- **Support** = how often the pair appears across all baskets
- **Confidence** = given product A is in the basket, how often is B also there
- **Lift** = Confidence / (how often B appears generally) — values above 1 mean the pair occurs more than chance

To keep the query from running forever, I filter to pairs that appear in at least a minimum number of baskets before calculating Lift. Otherwise the cross-join between basket items and itself creates an explosion of rare pairs.

## The Technical Struggle
The performance issue with this type of query is real. A self-join on millions of rows creates an explosion of pairs. My first attempt actually timed out MySQL.

**The Fix:** I realized I only care about pairs that occur enough times to be statistically relevant. By adding a `HAVING` clause to filter for a minimum support threshold (0.1% of orders) *before* calculating the math, I managed to get the query running in a few seconds.

**Bonus Struggle:** For the Daypart and Anchor analysis, I didn't want to just look at the top 10 items (which are always the same popular ones). I used `PERCENT_RANK()` and `volume_percentiles` to isolate behavior *within* the top tier of products. This ensures the results aren't skewed by low-volume outliers while still providing deep insights into our most important inventory.
## What I Learned
1. **Popularity is a liar:** Bananas have high co-occurrence with everything, but their Lift is low. It's the items like Hot Dogs and Buns that have the real 'causal' link.
2. **SQL is powerful but heavy:** Doing MBA in SQL is possible, but you have to be very careful with how you join tables or you'll crash your database. Performance optimization (indexing and thresholding) isn't optional—it's the only way the query finishes.
3. **The "Why" matters:** Finding out that Frozen items over-index at night isn't just a fun fact—it's a signal for when to send marketing emails.

## SQL Concepts Used

- Self-join on basket items to generate product pairs
- `CROSS JOIN` for benchmark denominators (total basket count)
- `NTILE(10)` for customer value decile segmentation
- `CASE WHEN HOUR(order_time)` for daypart bucketing
- Multi-stage CTEs to break the pipeline into readable steps
- `DENSE_RANK() OVER (ORDER BY ...)` for anchor product identification
- **Performance Tuning:** Implemented composite and secondary indexes to optimize multi-million row self-joins.

## How to Run

1. Run `schema.sql` to build the table structures and composite indexes.
2. Import the Instacart CSV files into MySQL 8.0+.
3. Run `analysis.sql` top to bottom.
