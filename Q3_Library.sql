/* =====================================================================
   ICT371  QUESTION 3 - Library Returns and Overdue Fines         [50]
   Rule: K2 per day AFTER due_on. Returned on due_on -> K0.
         A returned loan stops accumulating fines.
   ===================================================================== */
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - CHECK (due_on >= borrowed_on) is the required date rule.
   - returned_on is NULLable: NULL means "still out".
   - Seed dates are written relative to CURRENT_DATE so the "overdue" and
     "on-time" cases stay correct whenever the script is run.
   - Loans are inserted open; the returned ones are then closed through
     pr_return_loan (after the trigger exists) so they get audit rows and
     a correctly calculated fine.
   --------------------------------------------------------------------- */
CREATE TABLE books (
    book_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title    VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books (book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow    CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id          INTEGER     NOT NULL REFERENCES loans (loan_id),
    old_returned_on  DATE        NULL,
    new_returned_on  DATE        NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL CHECK (overdue_count >= 0),
    total_fine     NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Things Fall Apart'),
    ('Introduction to Algorithms');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mwila Banda',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, OVERDUE 16 days
    (2, 'Chanda Phiri',  CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 2 open, OVERDUE 6 days
    (3, 'Natasha Zulu',  CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 3 open, ON TIME (not yet due)
    (1, 'Joseph Mulenga',CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 4 will be returned early
    (2, 'Grace Tembo',   CURRENT_DATE - 35, CURRENT_DATE - 21),  -- 5 will be returned 3 days late
    (3, 'Peter Lungu',   CURRENT_DATE - 14, CURRENT_DATE - 7);   -- 6 will be returned ON the due date


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_loan_fine                                        [6]
   - End date = the EARLIER of p_as_of and returned_on (when returned).
     LEAST() is used; for an open loan the end date is simply p_as_of.
   - DATE - DATE in PostgreSQL gives whole days (an integer).
   - GREATEST(days_late, 0): returning early or on the due date gives 0,
     never a negative fine.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_due      loans.due_on%TYPE;
    v_returned loans.returned_on%TYPE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on
    INTO   v_due, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_returned);   -- returned: fines stop at return date
    ELSE
        v_end := p_as_of;                      -- still out: count up to p_as_of
    END IF;

    RETURN GREATEST(v_end - v_due, 0) * 2.00;  -- K2 per day late
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_return_loan                                     [8]
   - Rejects: NULL date, unknown loan, already returned loan, return
     before borrowed_on, and (sensible extra) a return in the future.
   - The final fine is calculated by the function AS OF the return date,
     then returned_on and fine_amount are written in ONE UPDATE, so they
     are always stored together.
   - FOR UPDATE stops two staff members returning the same loan twice.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed loans.borrowed_on%TYPE;
    v_returned loans.returned_on%TYPE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on
    INTO   v_borrowed, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;
    IF p_returned_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Return date % is in the future', p_returned_on;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET    returned_on = p_returned_on,
           fine_amount = v_fine
    WHERE  loan_id = p_loan_id;
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: AFTER UPDATE, FOR EACH ROW, on loans                 [8]
   - IS DISTINCT FROM is essential here: going from NULL (open) to a date
     is the most common change, and "NULL <> date" gives NULL (unknown),
     so a plain <> test would NEVER log a return. IS DISTINCT FROM treats
     NULL as an ordinary value: NULL vs date = different, NULL vs NULL =
     same.
   - Updating fine_amount or borrower_name alone writes no audit row.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_loans_return_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_return_audit();


-- (a) continued: close three loans through the procedure -------------
CALL pr_return_loan(4, CURRENT_DATE - 27);   -- 1 day early   -> K0
CALL pr_return_loan(5, CURRENT_DATE - 18);   -- 3 days late   -> K6
CALL pr_return_loan(6, CURRENT_DATE - 7);    -- on due date   -> K0

SELECT * FROM loans ORDER BY loan_id;

-- Tests for (b)
SELECT loan_id,
       fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today,
       fn_loan_fine(loan_id, CURRENT_DATE - 20) AS fine_20_days_ago
FROM   loans ORDER BY loan_id;
-- loan 1: 32.00 today; loan 5: stays 6.00 today (stopped at return);
CALL expect_error('SELECT fn_loan_fine(999, CURRENT_DATE)');

-- Tests for (c)
CALL expect_error('CALL pr_return_loan(999, CURRENT_DATE)');                 -- unknown
CALL expect_error('CALL pr_return_loan(5, CURRENT_DATE)');                   -- already returned
CALL expect_error('CALL pr_return_loan(3, CURRENT_DATE - 30)');              -- before borrowed_on

-- Tests for (d)
SELECT * FROM loan_audit ORDER BY audit_id;            -- 3 rows: NULL -> date
UPDATE loans SET fine_amount = fine_amount WHERE loan_id = 5;              -- no date change
UPDATE loans SET returned_on = returned_on WHERE loan_id = 5;              -- same date
SELECT count(*) AS audit_rows_still_3 FROM loan_audit;
UPDATE loans SET returned_on = CURRENT_DATE - 19 WHERE loan_id = 5;        -- correction
SELECT * FROM loan_audit ORDER BY audit_id DESC LIMIT 1;                   -- old & new date
UPDATE loans SET returned_on = CURRENT_DATE - 18 WHERE loan_id = 5;        -- put it back


/* ---------------------------------------------------------------------
   (e) VIEW v_overdue_loans                                          [5]
   - "Currently unreturned" = returned_on IS NULL.
   - "Due before CURRENT_DATE" = due_on < CURRENT_DATE (a loan due TODAY
     is not yet overdue).
   - The fine column reuses fn_loan_fine so the K2 rule lives in one place.
   - CURRENT_DATE inside a view is evaluated each time the view is
     queried, so the fine is always "as of today".
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
AND    l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY due_on;   -- loans 1 (K32) and 2 (K12)


/* ---------------------------------------------------------------------
   (f) INDEX                                                         [5]
   Search: "a given book's unreturned loans"
           WHERE book_id = ? AND returned_on IS NULL
   - PARTIAL index: only rows with returned_on IS NULL are stored in it.
     In a real library almost all loans are returned, so the index stays
     tiny and fast, and returned loans never cost index maintenance on
     later updates.
   - The query must contain the same predicate (returned_on IS NULL) for
     the planner to be allowed to use a partial index.
   --------------------------------------------------------------------- */
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

EXPLAIN
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM   loans
WHERE  book_id = 1
AND    returned_on IS NULL;

SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM   loans
WHERE  book_id = 1
AND    returned_on IS NULL;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   "Still unreturned as of p_as_of" (works for past dates too):
     borrowed_on <= p_as_of                      (it had been lent out)
     returned_on IS NULL OR returned_on > p_as_of (not back yet on that day)
     due_on < p_as_of                            (it was overdue that day)
   Fines are summed with fn_loan_fine(loan_id, p_as_of), which already
   stops at the return date. ON CONFLICT replaces the same snapshot_date.
   '10 0 * * *' = 00:10 every day, run for CURRENT_DATE.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
SET search_path = q3, public
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  borrowed_on <= p_as_of
    AND    (returned_on IS NULL OR returned_on > p_as_of)
    AND    due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET    overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);        -- rerun replaces the same row
CALL pr_refresh_overdue(CURRENT_DATE - 20);   -- historical snapshot
SELECT * FROM overdue_summary ORDER BY snapshot_date;

SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',
    $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q3_refresh_overdue';
