-- =====================================================================
--  HOSTEL MANAGEMENT SYSTEM  —  03_seed.sql
--  Sample data. Note how the triggers do real work while seeding:
--   * every student insert creates a login account
--   * every allocation bumps room occupancy
--   * every payment updates the invoice status
-- =====================================================================
SET search_path = hostel, public;
SELECT set_config('app.current_user', 'seed-script', false);

-- ---------------- Admin logins ----------------
INSERT INTO app_user (username, password_hash, role) VALUES
  ('admin',  crypt('admin123',  gen_salt('bf', 8)), 'ADMIN'),
  ('warden', crypt('warden123', gen_salt('bf', 8)), 'ADMIN');

-- ---------------- Departments ----------------
INSERT INTO department (dept_code, dept_name) VALUES
  ('CSE', 'Computer Science & Engineering'),
  ('ECE', 'Electronics & Communication Engineering'),
  ('ME',  'Mechanical Engineering'),
  ('CE',  'Civil Engineering'),
  ('EE',  'Electrical Engineering'),
  ('IT',  'Information Technology');

-- ---------------- Room types ----------------
INSERT INTO room_type (type_code, capacity, has_ac, description) VALUES
  ('SINGLE',    1, FALSE, 'Single occupancy, attached study table'),
  ('DOUBLE',    2, FALSE, 'Two-seater, shared wardrobe'),
  ('DOUBLE-AC', 2, TRUE,  'Two-seater with air conditioning'),
  ('TRIPLE',    3, FALSE, 'Three-seater, economical');

-- ---------------- Blocks ----------------
INSERT INTO hostel_block (block_code, block_name, gender, total_floors) VALUES
  ('A', 'Aryabhata Hall', 'M', 3),
  ('B', 'Raman Hall',     'M', 3),
  ('C', 'Kalpana Hall',   'F', 3);

-- ---------------- Staff ----------------
INSERT INTO staff (name, role, phone, block_id, salary, joined_on) VALUES
  ('Dr. Rajesh Verma',   'WARDEN',      '9810000001', 1, 65000, '2019-06-01'),
  ('Prof. Sunil Mehta',  'WARDEN',      '9810000002', 2, 62000, '2020-07-15'),
  ('Dr. Anjali Sharma',  'WARDEN',      '9810000003', 3, 64000, '2018-01-10'),
  ('Ramesh Yadav',       'SECURITY',    '9810000004', 1, 18000, '2021-03-01'),
  ('Sita Devi',          'SECURITY',    '9810000005', 3, 18000, '2022-02-01'),
  ('Mohan Lal',          'CLEANER',     '9810000006', 1, 14000, '2020-05-20'),
  ('Kamla Bai',          'CLEANER',     '9810000007', 3, 14000, '2021-08-11'),
  ('Suresh Kumar',       'ELECTRICIAN', '9810000008', NULL, 22000, '2019-11-01'),
  ('Abdul Rahim',        'PLUMBER',     '9810000009', NULL, 21000, '2020-01-15'),
  ('Harish Chand',       'CARPENTER',   '9810000010', NULL, 20000, '2023-04-01'),
  ('Lakshmi Iyer',       'MESS',        '9810000011', NULL, 25000, '2017-09-01'),
  ('Vikram Singh',       'CLEANER',     '9810000012', 2, 14000, '2024-01-05');

UPDATE hostel_block SET warden_id = block_id;   -- staff 1,2,3 are the wardens of blocks 1,2,3

-- ---------------- Rooms: 3 blocks x 3 floors x 6 rooms = 54 rooms ----------------
INSERT INTO room (block_id, room_no, floor, type_code)
SELECT b.block_id,
       (f * 100 + n)::text,
       f,
       CASE WHEN n = 1 THEN 'SINGLE'
            WHEN n IN (2, 3) THEN 'DOUBLE'
            WHEN n = 4 THEN 'DOUBLE-AC'
            ELSE 'TRIPLE' END
  FROM hostel_block b
 CROSS JOIN generate_series(1, 3) AS f
 CROSS JOIN generate_series(1, 6) AS n
 ORDER BY b.block_id, f, n;

-- ---------------- Students (trigger creates a login for each) ----------------
INSERT INTO student (roll_no, name, gender, dob, phone, email, dept_id, year_of_study,
                     guardian_name, guardian_phone, address, admitted_on) VALUES
  ('23CSE001','Aarav Sharma',    'M','2005-03-14','9876500001','aarav.sharma@college.edu',   1,2,'Rakesh Sharma',  '9876600001','Jaipur, Rajasthan',      '2023-07-20'),
  ('23CSE002','Vivaan Gupta',    'M','2005-06-02','9876500002','vivaan.gupta@college.edu',   1,2,'Anil Gupta',     '9876600002','Lucknow, Uttar Pradesh', '2023-07-20'),
  ('23ECE003','Aditya Kumar',    'M','2005-01-22','9876500003','aditya.kumar@college.edu',   2,2,'Sanjay Kumar',   '9876600003','Patna, Bihar',           '2023-07-20'),
  ('23ME004', 'Arjun Reddy',     'M','2004-11-30','9876500004','arjun.reddy@college.edu',    3,2,'Venkat Reddy',   '9876600004','Hyderabad, Telangana',   '2023-07-20'),
  ('24CSE005','Sai Krishna',     'M','2006-02-17','9876500005','sai.krishna@college.edu',    1,1,'Ravi Krishna',   '9876600005','Vijayawada, AP',         '2024-07-22'),
  ('24IT006', 'Reyansh Patel',   'M','2006-08-09','9876500006','reyansh.patel@college.edu',  6,1,'Nilesh Patel',   '9876600006','Ahmedabad, Gujarat',     '2024-07-22'),
  ('24EE007', 'Krishna Nair',    'M','2006-04-25','9876500007','krishna.nair@college.edu',   5,1,'Suresh Nair',    '9876600007','Kochi, Kerala',          '2024-07-22'),
  ('22CE008', 'Ishaan Joshi',    'M','2004-09-12','9876500008','ishaan.joshi@college.edu',   4,3,'Mahesh Joshi',   '9876600008','Pune, Maharashtra',      '2022-07-18'),
  ('22CSE009','Rohan Das',       'M','2004-05-05','9876500009','rohan.das@college.edu',      1,3,'Subrata Das',    '9876600009','Kolkata, West Bengal',   '2022-07-18'),
  ('22ME010', 'Kabir Singh',     'M','2004-12-19','9876500010','kabir.singh@college.edu',    3,3,'Harpreet Singh', '9876600010','Amritsar, Punjab',       '2022-07-18'),
  ('21ECE011','Dhruv Malhotra',  'M','2003-07-07','9876500011','dhruv.malhotra@college.edu', 2,4,'Vinod Malhotra', '9876600011','New Delhi',              '2021-07-15'),
  ('21CSE012','Ayaan Khan',      'M','2003-10-28','9876500012','ayaan.khan@college.edu',     1,4,'Imran Khan',     '9876600012','Bhopal, Madhya Pradesh', '2021-07-15'),
  ('23IT013', 'Laksh Agarwal',   'M','2005-02-11','9876500013','laksh.agarwal@college.edu',  6,2,'Pawan Agarwal',  '9876600013','Kanpur, Uttar Pradesh',  '2023-07-20'),
  ('23EE014', 'Pranav Iyer',     'M','2005-09-03','9876500014','pranav.iyer@college.edu',    5,2,'Ganesh Iyer',    '9876600014','Chennai, Tamil Nadu',    '2023-07-20'),
  ('24ME015', 'Yash Chauhan',    'M','2006-01-15','9876500015','yash.chauhan@college.edu',   3,1,'Devendra Chauhan','9876600015','Dehradun, Uttarakhand', '2024-07-22'),
  ('24CE016', 'Harsh Vardhan',   'M','2006-06-21','9876500016','harsh.vardhan@college.edu',  4,1,'Ashok Vardhan',  '9876600016','Varanasi, Uttar Pradesh','2024-07-22'),
  ('22IT017', 'Nikhil Bansal',   'M','2004-03-30','9876500017','nikhil.bansal@college.edu',  6,3,'Ramesh Bansal',  '9876600017','Chandigarh',             '2022-07-18'),
  ('22EE018', 'Tanmay Kulkarni', 'M','2004-08-14','9876500018','tanmay.kulkarni@college.edu',5,3,'Sudhir Kulkarni','9876600018','Nagpur, Maharashtra',    '2022-07-18'),
  ('21ME019', 'Siddharth Rao',   'M','2003-12-01','9876500019','siddharth.rao@college.edu',  3,4,'Prakash Rao',    '9876600019','Mangalore, Karnataka',   '2021-07-15'),
  ('21CE020', 'Manav Thakur',    'M','2003-04-18','9876500020','manav.thakur@college.edu',   4,4,'Rajinder Thakur','9876600020','Shimla, Himachal',       '2021-07-15'),
  ('24CSE021','Ritvik Saxena',   'M','2006-10-10','9876500021','ritvik.saxena@college.edu',  1,1,'Alok Saxena',    '9876600021','Gwalior, Madhya Pradesh','2024-07-22'),
  ('24ECE022','Parth Desai',     'M','2006-07-27','9876500022','parth.desai@college.edu',    2,1,'Kiran Desai',    '9876600022','Surat, Gujarat',         '2024-07-22'),
  ('23CSE023','Om Prakash',      'M','2005-05-23','9876500023','om.prakash@college.edu',     1,2,'Jai Prakash',    '9876600023','Ranchi, Jharkhand',      '2023-07-20'),
  ('23ME024', 'Dev Mishra',      'M','2005-11-08','9876500024','dev.mishra@college.edu',     3,2,'Umesh Mishra',   '9876600024','Allahabad, Uttar Pradesh','2023-07-20'),
  ('23CSE025','Ananya Singh',    'F','2005-04-04','9876500025','ananya.singh@college.edu',   1,2,'Rajeev Singh',   '9876600025','Gurugram, Haryana',      '2023-07-20'),
  ('23ECE026','Diya Mehta',      'F','2005-08-16','9876500026','diya.mehta@college.edu',     2,2,'Paresh Mehta',   '9876600026','Mumbai, Maharashtra',    '2023-07-20'),
  ('24IT027', 'Saanvi Rao',      'F','2006-03-12','9876500027','saanvi.rao@college.edu',     6,1,'Srinivas Rao',   '9876600027','Bengaluru, Karnataka',   '2024-07-22'),
  ('24CSE028','Myra Kapoor',     'F','2006-12-05','9876500028','myra.kapoor@college.edu',    1,1,'Sunil Kapoor',   '9876600028','New Delhi',              '2024-07-22'),
  ('22EE029', 'Aadhya Pillai',   'F','2004-02-26','9876500029','aadhya.pillai@college.edu',  5,3,'Mohan Pillai',   '9876600029','Thiruvananthapuram, Kerala','2022-07-18'),
  ('22CE030', 'Kavya Bhatt',     'F','2004-10-02','9876500030','kavya.bhatt@college.edu',    4,3,'Hemant Bhatt',   '9876600030','Udaipur, Rajasthan',     '2022-07-18'),
  ('21CSE031','Ishita Roy',      'F','2003-06-30','9876500031','ishita.roy@college.edu',     1,4,'Partha Roy',     '9876600031','Guwahati, Assam',        '2021-07-15'),
  ('21ME032', 'Priya Verma',     'F','2003-01-19','9876500032','priya.verma@college.edu',    3,4,'Arun Verma',     '9876600032','Indore, Madhya Pradesh', '2021-07-15'),
  ('23IT033', 'Riya Jain',       'F','2005-07-09','9876500033','riya.jain@college.edu',      6,2,'Manoj Jain',     '9876600033','Jodhpur, Rajasthan',     '2023-07-20'),
  ('24ECE034','Neha Choudhary',  'F','2006-05-28','9876500034','neha.choudhary@college.edu', 2,1,'Ajay Choudhary', '9876600034','Meerut, Uttar Pradesh',  '2024-07-22'),
  ('24ME035', 'Sneha Patil',     'F','2006-09-15','9876500035','sneha.patil@college.edu',    3,1,'Dilip Patil',    '9876600035','Kolhapur, Maharashtra',  '2024-07-22'),
  ('22CSE036','Tanvi Ghosh',     'F','2004-11-11','9876500036','tanvi.ghosh@college.edu',    1,3,'Amit Ghosh',     '9876600036','Durgapur, West Bengal',  '2022-07-18');

-- ---------------- Allocations via the stored procedure ----------------
-- Last 2 boys and last girl are left without a room so you can demo allocation.
DO $$
DECLARE
    s      RECORD;
    v_room INT;
BEGIN
    FOR s IN SELECT student_id, gender FROM student
              WHERE roll_no NOT IN ('23CSE023', '23ME024', '22CSE036')
              ORDER BY student_id
    LOOP
        SELECT room_id INTO v_room
          FROM v_vacant_rooms
         WHERE gender = s.gender
         ORDER BY (room_id * 7) % 19, room_id      -- spread students across rooms
         LIMIT 1;
        CALL allocate_room(s.student_id, v_room, DATE '2026-07-20');
    END LOOP;
END $$;

-- one room under maintenance (only if empty)
UPDATE room SET status = 'MAINTENANCE'
 WHERE room_id = (SELECT room_id FROM v_room_status
                   WHERE block_code = 'A' AND current_occupancy = 0
                   ORDER BY room_id LIMIT 1);

-- ---------------- Fee structure ----------------
INSERT INTO fee_structure (type_code, academic_year, semester, amount, due_date) VALUES
  ('SINGLE',    '2026-27', 1, 45000, '2026-08-15'),
  ('DOUBLE',    '2026-27', 1, 35000, '2026-08-15'),
  ('DOUBLE-AC', '2026-27', 1, 48000, '2026-08-15'),
  ('TRIPLE',    '2026-27', 1, 28000, '2026-08-15'),
  ('SINGLE',    '2026-27', 2, 45000, '2027-01-15'),
  ('DOUBLE',    '2026-27', 2, 35000, '2027-01-15'),
  ('DOUBLE-AC', '2026-27', 2, 48000, '2027-01-15'),
  ('TRIPLE',    '2026-27', 2, 28000, '2027-01-15');

SELECT generate_invoices('2026-27', 1);

-- payments: every 5th student has paid nothing, every 5th+1 paid partially, the rest in full
DO $$
DECLARE
    inv RECORD;
    k   INT := 0;
BEGIN
    FOR inv IN SELECT invoice_id, amount FROM invoice ORDER BY invoice_id LOOP
        k := k + 1;
        IF k % 5 = 0 THEN
            CONTINUE;
        ELSIF k % 5 = 1 THEN
            INSERT INTO payment (invoice_id, amount, paid_on, mode, txn_ref)
            VALUES (inv.invoice_id, 15000, TIMESTAMPTZ '2026-08-05 11:00' + k * INTERVAL '3 hours',
                    'UPI', 'UPI' || lpad(inv.invoice_id::text, 8, '0'));
        ELSE
            INSERT INTO payment (invoice_id, amount, paid_on, mode, txn_ref)
            VALUES (inv.invoice_id, inv.amount, TIMESTAMPTZ '2026-08-01 10:00' + k * INTERVAL '7 hours',
                    (ARRAY['UPI','CARD','NETBANKING','CASH'])[1 + k % 4],
                    'TXN' || lpad(inv.invoice_id::text, 8, '0'));
        END IF;
    END LOOP;
END $$;

SELECT apply_late_fines();

-- ---------------- Complaints ----------------
INSERT INTO complaint (student_id, category, description, priority, status, assigned_staff_id, created_at, resolved_at)
SELECT s.student_id, c.category, c.description, c.priority, c.status, c.staff_id, c.created_at, c.resolved_at
  FROM (VALUES
    ('23CSE001','ELECTRICAL','Ceiling fan makes a loud noise and runs very slowly',      'MEDIUM','RESOLVED',   8,  TIMESTAMPTZ '2026-09-02 09:15', TIMESTAMPTZ '2026-09-03 17:40'),
    ('23ECE003','PLUMBING',  'Bathroom tap leaking continuously since last night',       'HIGH',  'RESOLVED',   9,  TIMESTAMPTZ '2026-09-10 07:30', TIMESTAMPTZ '2026-09-10 15:00'),
    ('24CSE005','INTERNET',  'Wi-Fi not reachable on the second floor corridor',         'HIGH',  'IN_PROGRESS',8,  TIMESTAMPTZ '2026-11-08 21:00', NULL::timestamptz),
    ('22CE008', 'FURNITURE', 'Study chair is broken, one leg is loose',                  'LOW',   'OPEN',       NULL::int, TIMESTAMPTZ '2026-11-10 18:20', NULL),
    ('22CSE009','CLEANING',  'Corridor dustbins not cleared for two days',               'MEDIUM','OPEN',       NULL, TIMESTAMPTZ '2026-11-11 08:05', NULL),
    ('23CSE025','ELECTRICAL','Tube light in the room is flickering',                     'LOW',   'RESOLVED',   8,  TIMESTAMPTZ '2026-10-01 20:10', TIMESTAMPTZ '2026-10-02 12:00'),
    ('23ECE026','MESS',      'Food quality at dinner has dropped this week',             'MEDIUM','IN_PROGRESS',11, TIMESTAMPTZ '2026-11-05 22:00', NULL),
    ('24IT027', 'PLUMBING',  'No hot water in the morning in C block washrooms',         'HIGH',  'OPEN',       NULL, TIMESTAMPTZ '2026-11-12 06:45', NULL),
    ('21ECE011','FURNITURE', 'Cupboard lock is jammed and will not open',                'MEDIUM','RESOLVED',   10, TIMESTAMPTZ '2026-08-20 13:00', TIMESTAMPTZ '2026-08-22 11:30'),
    ('22IT017', 'OTHER',     'Room door does not close properly, needs alignment',       'LOW',   'OPEN',       NULL, TIMESTAMPTZ '2026-11-09 16:30', NULL)
  ) AS c(roll_no, category, description, priority, status, staff_id, created_at, resolved_at)
  JOIN student s ON s.roll_no = c.roll_no;

-- ---------------- Leave requests ----------------
INSERT INTO leave_request (student_id, from_date, to_date, reason, destination, status, reviewed_by, applied_on)
SELECT s.student_id, l.from_date, l.to_date, l.reason, l.destination, l.status,
       CASE WHEN l.status <> 'PENDING' THEN 1 END, l.applied_on
  FROM (VALUES
    ('23CSE001', DATE '2026-10-18', DATE '2026-10-25', 'Diwali vacation at home',        'Jaipur',     'APPROVED', TIMESTAMPTZ '2026-10-10 10:00'),
    ('22ME010',  DATE '2026-10-19', DATE '2026-10-23', 'Diwali with family',             'Amritsar',   'APPROVED', TIMESTAMPTZ '2026-10-11 12:00'),
    ('23CSE025', DATE '2026-11-20', DATE '2026-11-23', 'Cousin''s wedding',              'Gurugram',   'PENDING',  TIMESTAMPTZ '2026-11-12 09:30'),
    ('24CSE005', DATE '2026-11-28', DATE '2026-11-30', 'Medical check-up',               'Vijayawada', 'PENDING',  TIMESTAMPTZ '2026-11-13 08:00'),
    ('21ECE011', DATE '2026-11-15', DATE '2026-11-17', 'Job interview',                  'Bengaluru',  'APPROVED', TIMESTAMPTZ '2026-11-08 14:00'),
    ('22CE008',  DATE '2026-09-05', DATE '2026-09-06', 'Personal work',                  'Pune',       'REJECTED', TIMESTAMPTZ '2026-09-04 22:00'),
    ('24IT027',  DATE '2026-12-20', DATE '2027-01-02', 'Winter vacation',                'Bengaluru',  'PENDING',  TIMESTAMPTZ '2026-11-11 19:00')
  ) AS l(roll_no, from_date, to_date, reason, destination, status, applied_on)
  JOIN student s ON s.roll_no = l.roll_no;

-- ---------------- Visitors ----------------
INSERT INTO visitor (student_id, visitor_name, relation, phone, in_time, out_time)
SELECT s.student_id, v.visitor_name, v.relation, v.phone, v.in_time, v.out_time
  FROM (VALUES
    ('23CSE001', 'Rakesh Sharma',  'Father',  '9876600001', TIMESTAMPTZ '2026-11-01 11:00', TIMESTAMPTZ '2026-11-01 14:30'),
    ('24CSE005', 'Lakshmi Krishna','Mother',  '9876700005', TIMESTAMPTZ '2026-11-02 10:15', TIMESTAMPTZ '2026-11-02 13:00'),
    ('23CSE025', 'Rajeev Singh',   'Father',  '9876600025', TIMESTAMPTZ '2026-11-08 16:00', TIMESTAMPTZ '2026-11-08 18:10'),
    ('22ME010',  'Gurpreet Singh', 'Brother', '9876700010', TIMESTAMPTZ '2026-11-09 12:00', TIMESTAMPTZ '2026-11-09 12:45'),
    ('24IT027',  'Srinivas Rao',   'Father',  '9876600027', TIMESTAMPTZ '2026-11-13 10:00', NULL::timestamptz),
    ('21CSE012', 'Imran Khan',     'Father',  '9876600012', TIMESTAMPTZ '2026-11-13 11:30', NULL)
  ) AS v(roll_no, visitor_name, relation, phone, in_time, out_time)
  JOIN student s ON s.roll_no = v.roll_no;
