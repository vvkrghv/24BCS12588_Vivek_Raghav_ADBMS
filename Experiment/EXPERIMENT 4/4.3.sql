-- 1. All orders with Customers Details (Right Join)
SELECT c.customer_name, o.*
FROM customers c
RIGHT JOIN orders o ON c.customer_id = o.customer_id;

-- 2. Products and Categories (FULL OUTER JOIN)
SELECT p.product_name, c.category_name
FROM products p
FULL OUTER JOIN categories c ON p.category_id = c.category_id;

-- 3. All category names with product details (RIGHT JOIN)
select c.category_name, p.product_name, p.price
from products p
RIGHT JOIN categories c
on p.category_id = c.category_id;