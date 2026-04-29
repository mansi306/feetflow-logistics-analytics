-- =============================================================
--  FEETFLOW LOGISTICS — BUSINESS SQL QUERIES
--  Dialect  : MySQL 8.0+
--  Verified : Column names matched to actual database schema
-- =============================================================
--
--  ACTUAL TABLE SCHEMA
--  ───────────────────
--  orders   : order_id, order_date, actual_delivery_date,
--             order_status, hub_name, driver_id, driver_name,
--             vehicle_code, vehicle_type, is_delayed, is_on_time,
--             delay_reason, csat, delivery_hrs, hub_processing_hrs,
--             order_year, order_month, order_month_name,
--             order_quarter, order_dayofweek, is_weekend
--
--  hubs     : hub_id, hub_name, hub_capacity, total_orders,
--             delayed_orders, avg_csat, avg_proc_hrs,
--             cancelled, delay_rate, cancel_rate, utilisation_pct
--
--  vehicles : vehicle_id, vehicle_code, vehicle_model,
--             vehicle_status, purchase_date, breakdowns,
--             maintenance_alert, vehicle_age_yrs,
--             age_bucket, vehicle_type
--
--  drivers  : driver_id, driver_name, employment_type,
--             hire_date, experience_yrs, perf_rating,
--             total_orders, delayed_orders, avg_csat,
--             avg_delivery, delay_rate
-- =============================================================

USE feetflow;


-- ─────────────────────────────────────────────────────────────
-- QUERY 01 — Hub Performance Scorecard
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   Which hubs are delivering the best overall performance across
--   on-time rate, CSAT, and processing speed?
--
-- Key insight from data:
--   El Paso Hub ranks #1 on on-time rate (81.2%) despite the
--   smallest order volume — a best-practice benchmark.
--   Austin Hub ranks last (78.7%) and warrants investigation.
-- ─────────────────────────────────────────────────────────────

SELECT
    h.hub_name,
    h.hub_capacity,
    h.total_orders,
    h.delayed_orders,
    h.cancelled,
    ROUND(100 - h.delay_rate, 2)                              AS on_time_rate_pct,
    h.delay_rate,
    h.cancel_rate,
    h.avg_csat,
    h.avg_proc_hrs,
    h.utilisation_pct,

    -- Performance rank: 1 = best on-time rate
    RANK() OVER (
        ORDER BY h.delay_rate ASC
    )                                                         AS performance_rank,

    -- Flag hubs below fleet average on-time rate
    CASE
        WHEN h.delay_rate > AVG(h.delay_rate) OVER ()
        THEN 'Below Average'
        ELSE 'Above Average'
    END                                                       AS performance_flag

FROM hubs h
ORDER BY performance_rank;


-- ─────────────────────────────────────────────────────────────
-- QUERY 02 — Hub Capacity Utilisation vs Output
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   Are hubs working at, above, or below their stated capacity?
--   Which hubs have room to absorb more volume?
-- ─────────────────────────────────────────────────────────────

SELECT
    hub_name,
    hub_capacity,
    total_orders,
    utilisation_pct,
    CASE
        WHEN utilisation_pct >= 90  THEN 'High  (>=90%)'
        WHEN utilisation_pct >= 60  THEN 'Medium (60-89%)'
        ELSE                             'Low   (<60%)'
    END                                                       AS utilisation_band,

    -- How many orders/day the hub could still absorb
    ROUND(hub_capacity - (utilisation_pct / 100 * hub_capacity), 1)
                                                              AS spare_daily_capacity,

    -- Rank by how much headroom remains
    RANK() OVER (ORDER BY utilisation_pct ASC)                AS headroom_rank

FROM hubs
ORDER BY utilisation_pct DESC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 03 — Monthly On-Time Rate & CSAT Trend
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   How has delivery performance and customer satisfaction moved
--   month-over-month across the full 2-year period?
--
-- Note: order_year and order_month already exist in your orders
--       table as pre-computed columns — no date parsing needed.
-- ─────────────────────────────────────────────────────────────

WITH monthly_metrics AS (
    SELECT
        order_year,
        order_month,
        order_month_name,
        COUNT(order_id)                                                AS total_orders,
        SUM(CASE WHEN is_delayed = 1 THEN 1 ELSE 0 END)               AS delayed_orders,
        SUM(CASE WHEN order_status = 'Cancelled' THEN 1 ELSE 0 END)   AS cancelled_orders,
        ROUND(
            AVG(CASE WHEN is_on_time = 1 THEN 100.0 ELSE 0 END), 2
        )                                                              AS on_time_rate_pct,
        ROUND(AVG(csat), 3)                                            AS avg_csat,
        ROUND(AVG(delivery_hrs), 2)                                    AS avg_delivery_hrs,
        ROUND(AVG(hub_processing_hrs), 3)                              AS avg_hub_proc_hrs
    FROM   orders
    WHERE  order_status = 'Delivered'
    GROUP BY order_year, order_month, order_month_name
)
SELECT
    order_year,
    order_month,
    order_month_name,
    total_orders,
    delayed_orders,
    cancelled_orders,
    on_time_rate_pct,
    avg_csat,
    avg_delivery_hrs,
    avg_hub_proc_hrs,

    -- Month-over-month change in on-time rate
    ROUND(
        on_time_rate_pct
        - LAG(on_time_rate_pct) OVER (ORDER BY order_year, order_month),
        2
    )                                                                  AS mom_otr_change_pp,

    -- Rolling 3-month average (smooths out noise)
    ROUND(
        AVG(on_time_rate_pct) OVER (
            ORDER BY order_year, order_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        2
    )                                                                  AS rolling_3m_otr,

    -- Flag months below overall average
    CASE
        WHEN on_time_rate_pct < (
            SELECT AVG(on_time_rate_pct) FROM monthly_metrics
        ) - 1.5
        THEN 'Under-performing'
        ELSE 'Normal'
    END                                                                AS month_flag

FROM   monthly_metrics
ORDER BY order_year, order_month;


-- ─────────────────────────────────────────────────────────────
-- QUERY 04 — Year-over-Year Hub Comparison
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   For each hub, did performance improve or worsen from 2023
--   to 2024? Which hubs are trending in the right direction?
-- ─────────────────────────────────────────────────────────────

WITH yearly_hub AS (
    SELECT
        hub_name,
        order_year,
        COUNT(order_id)                                                AS total_orders,
        ROUND(
            AVG(CASE WHEN is_on_time = 1 THEN 100.0 ELSE 0 END), 2
        )                                                              AS on_time_rate_pct,
        ROUND(AVG(csat), 3)                                            AS avg_csat,
        ROUND(AVG(delivery_hrs), 2)                                    AS avg_delivery_hrs
    FROM   orders
    WHERE  order_status = 'Delivered'
    GROUP BY hub_name, order_year
)
SELECT
    y2023.hub_name,
    y2023.total_orders                                                 AS orders_2023,
    y2024.total_orders                                                 AS orders_2024,
    y2023.on_time_rate_pct                                             AS otr_2023,
    y2024.on_time_rate_pct                                             AS otr_2024,
    ROUND(y2024.on_time_rate_pct - y2023.on_time_rate_pct, 2)         AS otr_change_pp,
    y2023.avg_csat                                                     AS csat_2023,
    y2024.avg_csat                                                     AS csat_2024,
    ROUND(y2024.avg_csat - y2023.avg_csat, 3)                         AS csat_change,
    CASE
        WHEN y2024.on_time_rate_pct > y2023.on_time_rate_pct THEN 'Improved'
        WHEN y2024.on_time_rate_pct < y2023.on_time_rate_pct THEN 'Declined'
        ELSE                                                      'No Change'
    END                                                                AS yoy_trend
FROM       yearly_hub y2023
JOIN       yearly_hub y2024 ON y2023.hub_name = y2024.hub_name
WHERE      y2023.order_year = 2023
  AND      y2024.order_year = 2024
ORDER BY   otr_change_pp DESC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 05 — Delay Root Cause Analysis by Hub
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   What is causing delays at each hub? Which causes are
--   internal (controllable) vs external (uncontrollable)?
--
-- Key insight:
--   ~49% of delays are from internal causes — Package Sorting
--   Error, Driver Unavailable, Hub Processing Delay, Incorrect
--   Address, Multiple Delivery Stops. These are fixable.
-- ─────────────────────────────────────────────────────────────

WITH delay_counts AS (
    SELECT
        hub_name,
        delay_reason,
        COUNT(*)                                                AS delay_count
    FROM   orders
    WHERE  is_delayed = 1
      AND  delay_reason IS NOT NULL
    GROUP BY hub_name, delay_reason
),
hub_totals AS (
    SELECT hub_name, SUM(delay_count) AS hub_total_delays
    FROM   delay_counts
    GROUP BY hub_name
),
fleet_total AS (
    SELECT SUM(delay_count) AS fleet_total_delays
    FROM   delay_counts
)
SELECT
    dc.hub_name,
    dc.delay_reason,
    CASE
        WHEN dc.delay_reason IN (
            'Package Sorting Error',
            'Driver Unavailable',
            'Hub Processing Delay',
            'Incorrect Address',
            'Multiple Delivery Stops'
        ) THEN 'Internal - Controllable'
        ELSE   'External - Uncontrollable'
    END                                                         AS cause_category,
    dc.delay_count,
    ROUND(dc.delay_count * 100.0 / ht.hub_total_delays,  2)    AS pct_of_hub_delays,
    ROUND(dc.delay_count * 100.0 / ft.fleet_total_delays, 2)   AS pct_of_fleet_delays,

    -- Rank within each hub (1 = most common cause at that hub)
    RANK() OVER (
        PARTITION BY dc.hub_name
        ORDER BY dc.delay_count DESC
    )                                                           AS hub_rank

FROM       delay_counts dc
JOIN       hub_totals   ht ON dc.hub_name = ht.hub_name
CROSS JOIN fleet_total  ft
ORDER BY   dc.hub_name, dc.delay_count DESC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 06 — Driver Performance Leaderboard
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   Which drivers consistently outperform or underperform?
--   Does experience or rating predict delay rate?
--
-- Note: Your drivers table already has pre-aggregated metrics
--       (total_orders, delayed_orders, avg_csat, delay_rate)
--       so no JOIN to orders is needed for the main rankings.
-- ─────────────────────────────────────────────────────────────

SELECT
    driver_name,
    experience_yrs,
    perf_rating,
    employment_type,
    total_orders,
    delayed_orders,
    ROUND(delay_rate, 2)                                        AS delay_rate_pct,
    ROUND(avg_csat,   3)                                        AS avg_csat,
    ROUND(avg_delivery, 2)                                      AS avg_delivery_hrs,

    -- Quartile: 1 = top performers (fewest delays), 4 = worst
    NTILE(4) OVER (ORDER BY delay_rate ASC)                     AS delay_quartile,

    -- CSAT rank across all drivers
    RANK()   OVER (ORDER BY avg_csat DESC)                      AS csat_rank,

    -- Flag standout performers vs fleet average
    CASE
        WHEN delay_rate < (SELECT AVG(delay_rate) FROM drivers) - 2
        THEN 'Top Performer'
        WHEN delay_rate > (SELECT AVG(delay_rate) FROM drivers) + 2
        THEN 'Needs Coaching'
        ELSE 'Within Normal Range'
    END                                                         AS performance_flag

FROM   drivers
WHERE  total_orders >= 100        -- minimum volume for reliable stats
ORDER BY delay_rate ASC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 07 — CSAT Driver Analysis
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   What factors most affect customer satisfaction?
--   Does delay status, vehicle type, or delivery speed
--   explain CSAT variation?
--
-- Key insight:
--   Delivery time is the strongest predictor of CSAT
--   (r = -0.287, p < 0.001). Delayed orders score measurably
--   lower across all hubs and vehicle types.
-- ─────────────────────────────────────────────────────────────

-- Part A: CSAT by on-time vs delayed
SELECT
    'On-Time vs Delayed'                              AS breakdown_by,
    CASE WHEN is_delayed = 1 THEN 'Delayed'
         ELSE 'On Time' END                           AS segment,
    COUNT(order_id)                                   AS orders,
    ROUND(AVG(csat), 3)                               AS avg_csat,
    MIN(csat)                                         AS min_csat,
    MAX(csat)                                         AS max_csat
FROM   orders
WHERE  order_status = 'Delivered'
GROUP BY is_delayed

UNION ALL

-- Part B: CSAT by vehicle type
SELECT
    'Vehicle Type'                                    AS breakdown_by,
    vehicle_type                                      AS segment,
    COUNT(order_id)                                   AS orders,
    ROUND(AVG(csat), 3)                               AS avg_csat,
    MIN(csat)                                         AS min_csat,
    MAX(csat)                                         AS max_csat
FROM   orders
WHERE  order_status = 'Delivered'
GROUP BY vehicle_type

UNION ALL

-- Part C: CSAT by delivery time bucket
SELECT
    'Delivery Time Bucket'                            AS breakdown_by,
    CASE
        WHEN delivery_hrs < 12  THEN '1. Under 12 hrs'
        WHEN delivery_hrs < 24  THEN '2. 12-24 hrs'
        WHEN delivery_hrs < 48  THEN '3. 24-48 hrs'
        WHEN delivery_hrs < 72  THEN '4. 48-72 hrs'
        ELSE                         '5. Over 72 hrs'
    END                                               AS segment,
    COUNT(order_id)                                   AS orders,
    ROUND(AVG(csat), 3)                               AS avg_csat,
    MIN(csat)                                         AS min_csat,
    MAX(csat)                                         AS max_csat
FROM   orders
WHERE  order_status = 'Delivered'
GROUP BY segment

UNION ALL

-- Part D: CSAT by day of week (uses your pre-computed column)
SELECT
    'Day of Week'                                     AS breakdown_by,
    order_dayofweek                                   AS segment,
    COUNT(order_id)                                   AS orders,
    ROUND(AVG(csat), 3)                               AS avg_csat,
    MIN(csat)                                         AS min_csat,
    MAX(csat)                                         AS max_csat
FROM   orders
WHERE  order_status = 'Delivered'
GROUP BY order_dayofweek

ORDER BY breakdown_by, segment;


-- ─────────────────────────────────────────────────────────────
-- QUERY 08 — Vehicle Breakdown Risk Ranking
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   Which vehicles are highest-risk for breakdowns?
--   Does vehicle age predict maintenance burden?
--
-- Note: vehicle_age_yrs and age_bucket are already in your
--       vehicles table — no date calculation needed.
--
-- Key insight:
--   Vehicle age strongly predicts breakdowns (r = 0.649,
--   p < 0.001). 26.7% of fleet currently in maintenance.
-- ─────────────────────────────────────────────────────────────

SELECT
    vehicle_code,
    vehicle_model,
    vehicle_type,
    vehicle_status,
    vehicle_age_yrs,
    age_bucket,
    breakdowns,
    maintenance_alert,

    -- Composite risk score: higher = more urgent attention
    ROUND(
        (vehicle_age_yrs * 2) + (breakdowns * 3) + (maintenance_alert * 5),
        1
    )                                                           AS breakdown_risk_score,

    CASE
        WHEN vehicle_age_yrs >= 7 AND breakdowns >= 20 THEN 'High Risk - Review Now'
        WHEN vehicle_age_yrs >= 5 OR  breakdowns >= 15 THEN 'Medium Risk - Monitor'
        ELSE                                                'Low Risk - Normal'
    END                                                         AS risk_flag,

    -- How this vehicle compares to others of the same model
    ROUND(AVG(breakdowns) OVER (PARTITION BY vehicle_model), 1) AS model_avg_breakdowns,
    ROUND(
        breakdowns - AVG(breakdowns) OVER (PARTITION BY vehicle_model),
        1
    )                                                           AS vs_model_average,

    -- Rank within vehicle type
    RANK() OVER (
        PARTITION BY vehicle_type
        ORDER BY breakdowns DESC
    )                                                           AS rank_in_type

FROM   vehicles
ORDER BY breakdown_risk_score DESC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 09 — Fleet Status & Maintenance Impact
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   How many vehicles are active vs in maintenance by model?
--   What capacity are we losing to maintenance right now?
-- ─────────────────────────────────────────────────────────────

SELECT
    vehicle_model,
    COUNT(vehicle_id)                                                AS total_vehicles,
    SUM(CASE WHEN vehicle_status = 'Active'      THEN 1 ELSE 0 END) AS active,
    SUM(CASE WHEN vehicle_status = 'Maintenance' THEN 1 ELSE 0 END) AS in_maintenance,
    ROUND(
        SUM(CASE WHEN vehicle_status = 'Maintenance' THEN 1 ELSE 0 END)
        * 100.0 / COUNT(vehicle_id),
        1
    )                                                                AS pct_in_maintenance,
    ROUND(AVG(breakdowns),        1)                                 AS avg_breakdowns,
    ROUND(AVG(maintenance_alert), 1)                                 AS avg_maintenance_alerts,
    ROUND(MIN(vehicle_age_yrs),   1)                                 AS youngest_vehicle_age,
    ROUND(MAX(vehicle_age_yrs),   1)                                 AS oldest_vehicle_age,
    ROUND(AVG(vehicle_age_yrs),   1)                                 AS avg_vehicle_age_yrs

FROM   vehicles
GROUP BY vehicle_model

UNION ALL

-- Fleet-wide totals row
SELECT
    'FLEET TOTAL',
    COUNT(vehicle_id),
    SUM(CASE WHEN vehicle_status = 'Active'      THEN 1 ELSE 0 END),
    SUM(CASE WHEN vehicle_status = 'Maintenance' THEN 1 ELSE 0 END),
    ROUND(
        SUM(CASE WHEN vehicle_status = 'Maintenance' THEN 1 ELSE 0 END)
        * 100.0 / COUNT(vehicle_id), 1
    ),
    ROUND(AVG(breakdowns),        1),
    ROUND(AVG(maintenance_alert), 1),
    ROUND(MIN(vehicle_age_yrs),   1),
    ROUND(MAX(vehicle_age_yrs),   1),
    ROUND(AVG(vehicle_age_yrs),   1)
FROM   vehicles

-- FLEET TOTAL row always appears last
ORDER BY
    CASE WHEN vehicle_model = 'FLEET TOTAL' THEN 1 ELSE 0 END ASC,
    pct_in_maintenance DESC;


-- ─────────────────────────────────────────────────────────────
-- QUERY 10 — Executive KPI Summary
-- ─────────────────────────────────────────────────────────────
-- Business question:
--   What are the headline numbers for 2023 vs 2024?
--
-- Note: Uses order_year (pre-computed) instead of YEAR(order_date)
--       since your orders table already has this column.
-- ─────────────────────────────────────────────────────────────
WITH yearly_orders AS (
    SELECT
        order_year,
        COUNT(order_id)                                                   AS total_orders,
        SUM(CASE WHEN order_status = 'Delivered' THEN 1 ELSE 0 END)       AS delivered_count,
        SUM(CASE WHEN order_status = 'Cancelled' THEN 1 ELSE 0 END)       AS cancelled_count,
        SUM(CASE WHEN is_delayed = 1 THEN 1 ELSE 0 END)                   AS delayed_count,
        SUM(CASE WHEN is_on_time = 1 THEN 1 ELSE 0 END)                   AS on_time_count,
        ROUND(AVG(csat),              3)                                  AS avg_csat,
        ROUND(AVG(delivery_hrs),      2)                                  AS avg_delivery_hrs,
        ROUND(AVG(hub_processing_hrs),3)                                  AS avg_hub_proc_hrs,
        /* Weekend vs weekday split (uses your pre-computed column) */
        SUM(CASE WHEN is_weekend = 1 THEN 1 ELSE 0 END)                  AS weekend_orders,
        SUM(CASE WHEN is_weekend = 0 THEN 1 ELSE 0 END)                  AS weekday_orders
    FROM orders
    GROUP BY order_year
),
fleet_snapshot AS (
    SELECT
        COUNT(vehicle_id)                                                  AS total_vehicles,
        SUM(CASE WHEN vehicle_status = 'Active'      THEN 1 ELSE 0 END)    AS active_vehicles,
        SUM(CASE WHEN vehicle_status = 'Maintenance' THEN 1 ELSE 0 END)    AS vehicles_in_maintenance,
        ROUND(AVG(vehicle_age_yrs), 1)                                     AS avg_fleet_age
    FROM vehicles
),
driver_snapshot AS (
    SELECT
        COUNT(driver_id)              AS total_drivers,
        ROUND(AVG(delay_rate), 2)     AS fleet_avg_delay_rate,
        ROUND(AVG(avg_csat),   3)     AS fleet_avg_driver_csat,
        ROUND(AVG(experience_yrs), 1) AS avg_experience_yrs
    FROM drivers
)
SELECT
    o.order_year,
    o.total_orders,
    o.delivered_count,
    o.cancelled_count,
    ROUND(o.cancelled_count * 100.0 / NULLIF(o.total_orders, 0), 2)     AS cancellation_rate_pct,
    o.delayed_count,
    o.on_time_count,
    ROUND(o.on_time_count * 100.0 / NULLIF(o.delivered_count, 0), 2)    AS on_time_rate_pct,
    ROUND(o.delayed_count * 100.0 / NULLIF(o.delivered_count, 0), 2)    AS delay_rate_pct,
    o.avg_csat,
    o.avg_delivery_hrs,
    o.avg_hub_proc_hrs,
    o.weekend_orders,
    o.weekday_orders,
    f.total_vehicles,
    f.active_vehicles,
    f.vehicles_in_maintenance,
    ROUND(f.vehicles_in_maintenance * 100.0 / NULLIF(f.total_vehicles, 0), 1) AS fleet_maintenance_pct,
    f.avg_fleet_age,
    d.total_drivers,
    d.fleet_avg_delay_rate,
    d.avg_experience_yrs
FROM yearly_orders o
CROSS JOIN fleet_snapshot f
CROSS JOIN driver_snapshot d
ORDER BY o.order_year;


-- =============================================================
-- END OF FILE
-- Queries : 10
-- Dialect : MySQL 8.0+
-- Schema  : Matched to actual DESCRIBE output from your database
-- =============================================================
