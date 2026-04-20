/* =========================================================
SCHEMA FILE: Customer Behavior and Market Basket Intelligence
AUTHOR: Shivam Kumar
DIALECT: MySQL 8+
PURPOSE: Table definitions and schema setup for the project.
========================================================= */

CREATE DATABASE IF NOT EXISTS market_basket;
USE market_basket;

DROP TABLE IF EXISTS order_products__train;
DROP TABLE IF EXISTS order_products__prior;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS aisles;
DROP TABLE IF EXISTS departments;

-- ---------------------------------------------------------
-- DIMENSION TABLES
-- ---------------------------------------------------------

CREATE TABLE departments (
    department_id INT PRIMARY KEY,
    department VARCHAR(100) NOT NULL
);

CREATE TABLE aisles (
    aisle_id INT PRIMARY KEY,
    aisle VARCHAR(150) NOT NULL
);

CREATE TABLE products (
    product_id INT PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    aisle_id INT NOT NULL,
    department_id INT NOT NULL,
    FOREIGN KEY (aisle_id) REFERENCES aisles(aisle_id),
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

-- ---------------------------------------------------------
-- FACT TABLES
-- ---------------------------------------------------------

CREATE TABLE orders (
    order_id INT PRIMARY KEY,
    user_id INT NOT NULL,
    eval_set VARCHAR(20),
    order_number INT,
    order_dow INT,
    order_hour_of_day INT,
    days_since_prior_order DECIMAL(10,2),
    INDEX idx_user_id (user_id) -- Speeds up customer-level aggregations
);

CREATE TABLE order_products__prior (
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    add_to_cart_order INT,
    reordered INT,
    PRIMARY KEY (order_id, product_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    INDEX idx_order_id (order_id),
    INDEX idx_product_id (product_id) -- Essential for self-joins and Lift calculations
);

CREATE TABLE order_products__train (
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    add_to_cart_order INT,
    reordered INT,
    PRIMARY KEY (order_id, product_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    INDEX idx_order_id_train (order_id),
    INDEX idx_product_id_train (product_id)
);

/* =========================================================
OPTIMIZATION NOTES
- Composite PKs (order_id, product_id) are used for data integrity.
- Secondary indexes on product_id are crucial for Section 3 (Market Basket).
- Index on user_id supports Pareto and customer-lifetime analysis.
========================================================= */
