-- ============================================================================
-- CSA05 Special Assessment 2
-- National Vocational Certification and Exam Slot-Booking System
-- Complete SQL DDL Script (MySQL 8.0 / InnoDB)
-- ============================================================================

-- Create and select database
CREATE DATABASE IF NOT EXISTS nvcert
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE nvcert;

-- Drop existing objects (safe re-run)
DROP TABLE IF EXISTS results;
DROP TABLE IF EXISTS exam_attempts;
DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS exam_slots;
DROP TABLE IF EXISTS centers;
DROP TABLE IF EXISTS candidates;

-- ============================================================================
-- 1. CANDIDATES
-- ============================================================================
CREATE TABLE candidates (
  candidate_id      BIGINT          NOT NULL,
  full_name         VARCHAR(120)    NOT NULL,
  email             VARCHAR(150)    NULL,
  phone             VARCHAR(20)     NULL,
  registered_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (candidate_id),
  KEY idx_candidates_name (full_name)
) ENGINE=InnoDB;

-- ============================================================================
-- 2. CENTERS
-- ============================================================================
CREATE TABLE centers (
  center_id         INT             NOT NULL,
  center_name       VARCHAR(100)    NOT NULL,
  city              VARCHAR(60)     NULL,
  capacity_per_slot SMALLINT        NOT NULL,
  PRIMARY KEY (center_id),
  CONSTRAINT chk_center_capacity CHECK (capacity_per_slot > 0)
) ENGINE=InnoDB;

-- ============================================================================
-- 3. EXAM_SLOTS
-- ============================================================================
CREATE TABLE exam_slots (
  slot_id           BIGINT          NOT NULL AUTO_INCREMENT,
  center_id         INT             NOT NULL,
  exam_date         DATE            NOT NULL,
  start_time        TIME            NOT NULL,
  end_time          TIME            NOT NULL,
  max_capacity      SMALLINT        NOT NULL,
  booked_count      SMALLINT        NOT NULL DEFAULT 0,
  PRIMARY KEY (slot_id),
  KEY idx_slot_center_date (center_id, exam_date),
  KEY idx_slot_date (exam_date),
  CONSTRAINT fk_slot_center
    FOREIGN KEY (center_id) REFERENCES centers (center_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT chk_slot_capacity
    CHECK (booked_count >= 0 AND booked_count <= max_capacity),
  CONSTRAINT chk_slot_times
    CHECK (end_time > start_time)
) ENGINE=InnoDB;

-- ============================================================================
-- 4. BOOKINGS
-- ============================================================================
CREATE TABLE bookings (
  booking_id        BIGINT          NOT NULL AUTO_INCREMENT,
  candidate_id      BIGINT          NOT NULL,
  slot_id           BIGINT          NOT NULL,
  booking_ts        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status            ENUM('CONFIRMED','CANCELLED') NOT NULL DEFAULT 'CONFIRMED',
  PRIMARY KEY (booking_id),
  UNIQUE KEY uk_candidate_slot (candidate_id, slot_id),
  KEY idx_bookings_slot (slot_id),
  KEY idx_bookings_candidate (candidate_id),
  CONSTRAINT fk_book_cand
    FOREIGN KEY (candidate_id) REFERENCES candidates (candidate_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_book_slot
    FOREIGN KEY (slot_id) REFERENCES exam_slots (slot_id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================================
-- 5. EXAM_ATTEMPTS  (high-volume archive)
--    Clustered on attempt_id (sequential insertion locality)
--    Secondary B+-tree indexes for candidate-history and center-audit
-- ============================================================================
CREATE TABLE exam_attempts (
  attempt_id        BIGINT          NOT NULL AUTO_INCREMENT,
  candidate_id      BIGINT          NOT NULL,
  center_id         INT             NOT NULL,
  exam_date         DATE            NOT NULL,
  slot_id           BIGINT          NULL,
  responses         JSON            NULL,
  timing_data       JSON            NULL,
  raw_score         DECIMAL(6,2)    NULL,
  status            ENUM('IN_PROGRESS','COMPLETED','ABSENT')
                                    NOT NULL DEFAULT 'COMPLETED',
  created_at        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (attempt_id),
  -- Candidate history: equality + ordered history
  KEY idx_candidate_history (candidate_id, exam_date DESC),
  -- Center-wise audit: equality on center + date range
  KEY idx_center_audit (center_id, exam_date, attempt_id),
  -- Supporting booking joins
  KEY idx_attempt_slot (slot_id),
  CONSTRAINT fk_att_cand
    FOREIGN KEY (candidate_id) REFERENCES candidates (candidate_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_att_center
    FOREIGN KEY (center_id) REFERENCES centers (center_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_att_slot
    FOREIGN KEY (slot_id) REFERENCES exam_slots (slot_id)
    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================================
-- 6. RESULTS  (optimistic concurrency via version column)
-- ============================================================================
CREATE TABLE results (
  result_id         BIGINT          NOT NULL AUTO_INCREMENT,
  attempt_id        BIGINT          NOT NULL,
  published_score   DECIMAL(6,2)    NULL,
  grade             CHAR(2)         NULL,
  published_by      INT             NULL,
  published_at      DATETIME        NULL,
  version           INT             NOT NULL DEFAULT 1,
  PRIMARY KEY (result_id),
  UNIQUE KEY uk_result_attempt (attempt_id),
  CONSTRAINT fk_res_att
    FOREIGN KEY (attempt_id) REFERENCES exam_attempts (attempt_id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================================
-- STORED PROCEDURE: book_slot
-- Atomic capacity-checked booking under REPEATABLE READ
-- ============================================================================
DELIMITER //

CREATE PROCEDURE book_slot (
  IN  p_candidate_id  BIGINT,
  IN  p_slot_id       BIGINT,
  OUT p_status        VARCHAR(30),
  OUT p_message       VARCHAR(100)
)
BEGIN
  DECLARE v_max     SMALLINT;
  DECLARE v_booked  SMALLINT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    SET p_status  = 'ERROR';
    SET p_message = 'Transaction failed – see server log';
  END;

  START TRANSACTION;

  -- Exclusive lock on the slot row (prevents double-booking)
  SELECT max_capacity, booked_count
    INTO v_max, v_booked
    FROM exam_slots
   WHERE slot_id = p_slot_id
   FOR UPDATE;

  IF v_booked IS NULL THEN
    ROLLBACK;
    SET p_status  = 'ERROR';
    SET p_message = 'Slot does not exist';
  ELSEIF v_booked >= v_max THEN
    ROLLBACK;
    SET p_status  = 'REJECTED';
    SET p_message = 'Slot capacity exceeded';
  ELSE
    INSERT INTO bookings (candidate_id, slot_id, status)
    VALUES (p_candidate_id, p_slot_id, 'CONFIRMED');

    UPDATE exam_slots
       SET booked_count = booked_count + 1
     WHERE slot_id = p_slot_id;

    COMMIT;
    SET p_status  = 'CONFIRMED';
    SET p_message = 'Booking successful';
  END IF;
END //

-- ============================================================================
-- STORED PROCEDURE: publish_result
-- Optimistic concurrency control via version column
-- ============================================================================
CREATE PROCEDURE publish_result (
  IN  p_attempt_id       BIGINT,
  IN  p_score            DECIMAL(6,2),
  IN  p_grade            CHAR(2),
  IN  p_examiner_id      INT,
  IN  p_expected_version INT,
  OUT p_status           VARCHAR(30),
  OUT p_message          VARCHAR(100)
)
BEGIN
  DECLARE v_rows INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    SET p_status  = 'ERROR';
    SET p_message = 'Transaction failed – see server log';
  END;

  START TRANSACTION;

  UPDATE results
     SET published_score = p_score,
         grade           = p_grade,
         published_by    = p_examiner_id,
         published_at    = NOW(),
         version         = version + 1
   WHERE attempt_id = p_attempt_id
     AND version    = p_expected_version;

  SET v_rows = ROW_COUNT();

  IF v_rows = 0 THEN
    -- Either no row or version conflict
    ROLLBACK;
    SET p_status  = 'CONFLICT';
    SET p_message = 'Concurrent update detected or result missing – refresh and retry';
  ELSE
    COMMIT;
    SET p_status  = 'PUBLISHED';
    SET p_message = 'Result published successfully';
  END IF;
END //

DELIMITER ;

-- ============================================================================
-- Sample data (minimal) for quick testing
-- ============================================================================
INSERT INTO candidates (candidate_id, full_name, email) VALUES
  (100234567890, 'Aarav Sharma',   'aarav@example.com'),
  (100234567891, 'Diya Patel',     'diya@example.com'),
  (100234567892, 'Rohan Mehta',    'rohan@example.com'),
  (100234567893, 'Ananya Singh',   'ananya@example.com'),
  (100234567894, 'Vikram Reddy',   'vikram@example.com');

INSERT INTO centers (center_id, center_name, city, capacity_per_slot) VALUES
  (1001, 'Delhi Central Lab',      'New Delhi', 40),
  (1002, 'Mumbai West Center',     'Mumbai',    50),
  (1003, 'Bengaluru Tech Hub',     'Bengaluru', 35);

INSERT INTO exam_slots (center_id, exam_date, start_time, end_time, max_capacity, booked_count) VALUES
  (1001, '2026-09-15', '09:00:00', '12:00:00', 40, 0),
  (1001, '2026-09-15', '14:00:00', '17:00:00', 40, 0),
  (1002, '2026-09-16', '09:00:00', '12:00:00', 50, 0),
  (1003, '2026-09-17', '10:00:00', '13:00:00', 35, 0);

-- Example attempt records (illustrative)
INSERT INTO exam_attempts (candidate_id, center_id, exam_date, slot_id, raw_score, status) VALUES
  (100234567890, 1001, '2026-09-15', 1, 78.50, 'COMPLETED'),
  (100234567891, 1001, '2026-09-15', 1, 82.00, 'COMPLETED'),
  (100234567892, 1002, '2026-09-16', 3, 65.75, 'COMPLETED');

INSERT INTO results (attempt_id, published_score, grade, published_by, published_at, version) VALUES
  (1, 78.50, 'B+', 501, NOW(), 1),
  (2, 82.00, 'A',  501, NOW(), 1);

-- ============================================================================
-- Useful verification queries
-- ============================================================================
-- SHOW INDEX FROM exam_attempts;
-- EXPLAIN SELECT * FROM exam_attempts WHERE candidate_id = 100234567890 ORDER BY exam_date DESC;
-- EXPLAIN SELECT * FROM exam_attempts WHERE center_id = 1001 AND exam_date = '2026-09-15';

-- CALL book_slot(100234567893, 1, @st, @msg); SELECT @st, @msg;
-- CALL publish_result(1, 79.00, 'B+', 502, 1, @st, @msg); SELECT @st, @msg;

-- ============================================================================
-- End of DDL script
-- ============================================================================
