/* Write a query to count the number of students across departments who has scored more than 80 marks.*/
select
  department,
  COUNT(CASE WHEN marks>80 THEN 1 ELSE NULL END) as Dept_HighScore_Count
  from student
  GROUP BY department;