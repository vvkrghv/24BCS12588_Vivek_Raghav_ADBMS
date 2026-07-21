/* Write a query to output a single table with the names of employees in both  the table 'employee' and 'pt_employee'.
Employee names are added on the field emp_name in both the tables.
Note: Do not remove the duplicate names while combining both the tables. */
select emp_name from employee
UNION ALL
SELECT emp_name from pt_employee;