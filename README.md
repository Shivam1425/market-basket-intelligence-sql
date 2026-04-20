# Market Basket Intelligence & Association Rules

**Author:** Shivam Kumar  
**SQL Dialect:** MySQL 8.0+  
**Dataset:** [Instacart Market Basket Analysis (Kaggle)](https://www.kaggle.com/code/brightboakye/market-basket-analysis-instacart)

## What This Project Is About

Most "product analysis" in SQL portfolios is just `SELECT product, COUNT(*) ORDER BY DESC LIMIT 10`. That tells you what's popular, but it's pretty basic. 

I wanted to go deeper. I wrote the Association Rule Mining math (Support, Confidence, and Lift) directly in SQL to find out which products people *actually* buy together. I also looked for "Churn Traps" (items people try once but never reorder) and "Daypart Affinity" to see how shopping habits change from morning to night.

## What I Was Trying to Answer

1. Which product pairs have the highest Lift? High Lift means customers buy them together more than random chance would predict — that's a real complementary relationship worth acting on.
2. Which products get a lot of first-time purchases but almost never get reordered? These are the "Churn Traps" — they inflate trial numbers while damaging customer LTV.
3. Which product departments are heavy morning purchases vs evening purchases? Knowing this lets you time push notifications by department.
4. Which items do customers add to their cart first? Items added first are "destination items" — a stockout on them likely causes full cart abandonment.
5. How concentrated is spend across customer deciles?

## What I Found

- Hot Dogs and Buns had a Lift score of 3.42 — customers buy them together 3.42x more than would be expected if purchases were independent. That's a genuinely strong signal for bundling or joint placement.
- The Churn Trap products were the most surprising finding. Some items had thousands of first-time orders but near-zero reorder rates. These are probably impulse buys or trial purchases that disappoint — exactly the kind of thing a merchandising team needs to investigate.
- Daypart affinity is real and measurable. Certain departments (snacks, beverages) over-index significantly in evening orders, which has direct implications for notification timing.
- The top decile of customers generates a disproportionate share of revenue — the Power Law holds even in grocery data.

### **Product Churn Analysis (The "One-Hit Wonders")**
I identified products with high trial volume but near-zero reorders. These are potential quality or expectation "churn traps."
![Product Churn Analysis](assets/churn_traps.png)

**Sample output — Top Product Pair Lift Scores (Section 8):**

| product_1 | product_2 | baskets_together | support_pct | confidence_pct | lift |
|---|---|---|---|---|---|
| Hot Dogs | Hot Dog Buns | 3,241 | 2.14% | 68.4% | 3.42 |
| Strawberries | Raspberries | 5,872 | 3.87% | 52.1% | 2.98 |
| Limes | Avocados | 4,119 | 2.72% | 49.3% | 2.71 |
| Whole Milk | Organic Whole Milk | 6,340 | 4.18% | 44.7% | 1.89 |
| Bananas | Organic Bananas | 9,876 | 6.51% | 71.2% | 1.43 |

### **Daypart Affinity & Behavior**
Certain departments (like Alcohol and Snacks) significantly over-index in evening orders.
![Daypart Affinity](assets/daypart_affinity.png)

### **Anchor Product Identification**
Items like Water Mineral and Milk are almost always added to the cart first, acting as "destination" items.
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

I also initially forgot the `AND a.product_id < b.product_id` condition. I couldn't figure out why my results were doubled and the math was off until I realized I was counting both (Hot Dogs, Buns) and (Buns, Hot Dogs) as separate events. 

## What I Learned
1. **Popularity is a liar:** Bananas have high co-occurrence with everything, but their Lift is low. It's the items like Hot Dogs and Buns that have the real 'causal' link.
2. **SQL is powerful but heavy:** Doing MBA in SQL is possible, but you have to be very careful with how you join tables or you'll crash your database.
3. **The "Why" matters:** Finding out that Alcohol over-indexes at night isn't just a fun fact—it's a signal for when to send marketing emails.

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
