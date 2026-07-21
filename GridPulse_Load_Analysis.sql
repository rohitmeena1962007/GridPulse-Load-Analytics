-- =====================================================================
-- GridPulse - Household Electricity Load & Peak-Demand Analytics
-- MySQL 8.0 script: schema, CSV load, analytical queries
-- Data: UCI Individual Household Electric Power Consumption (hourly, cleaned)
-- =====================================================================

CREATE DATABASE IF NOT EXISTS gridpulse_energy;
USE gridpulse_energy;

DROP TABLE IF EXISTS fact_hourly_load;
DROP TABLE IF EXISTS dim_tariff_tiers;
DROP TABLE IF EXISTS dim_calendar;

CREATE TABLE dim_calendar (
    date_id         INT          NOT NULL PRIMARY KEY,      -- yyyymmdd
    full_date       DATE         NOT NULL,
    `year`          SMALLINT     NOT NULL,
    `month`         TINYINT      NOT NULL,
    season_label    VARCHAR(10)  NOT NULL,                   -- Winter / Spring / Summer / Autumn
    day_of_week     VARCHAR(10)  NOT NULL,
    day_type_label  VARCHAR(10)  NOT NULL                    -- Weekday / Weekend
);

CREATE TABLE dim_tariff_tiers (
    hour_id              TINYINT       NOT NULL PRIMARY KEY, -- 0..23
    hour_label           CHAR(5)       NOT NULL,             -- 00:00 .. 23:00
    tou_tier_label       VARCHAR(30)   NOT NULL,
    tariff_rate_usd_kwh  DECIMAL(5,3)  NOT NULL              -- illustrative time-of-use rate
);

CREATE TABLE fact_hourly_load (
    hourly_id                    INT           NOT NULL PRIMARY KEY,
    `timestamp`                  DATETIME      NOT NULL,
    date_id                      INT           NOT NULL,
    hour_id                      TINYINT       NOT NULL,
    global_active_power_kw       DECIMAL(8,4),
    global_reactive_power_kvar   DECIMAL(8,4),
    voltage_v                    DECIMAL(8,3),
    global_intensity_a           DECIMAL(8,3),
    sub_metering_1_kitchen_wh    DECIMAL(10,3),
    sub_metering_2_laundry_wh    DECIMAL(10,3),
    sub_metering_3_hvac_wh       DECIMAL(10,3),
    unmetered_other_wh           DECIMAL(10,3),
    imputed_minutes_count        TINYINT,
    shifted_load_kw              DECIMAL(8,4),
    CONSTRAINT fk_fact_calendar FOREIGN KEY (date_id) REFERENCES dim_calendar (date_id),
    CONSTRAINT fk_fact_tariff   FOREIGN KEY (hour_id) REFERENCES dim_tariff_tiers (hour_id),
    INDEX idx_fact_date (date_id),
    INDEX idx_fact_hour (hour_id)
);

-- ---------------------------------------------------------------------
-- Load the CSVs (adjust the folder; needs local_infile enabled).
-- Alternatively run the notebook, which loads the tables with pandas.to_sql().
-- ---------------------------------------------------------------------
-- LOAD DATA LOCAL INFILE 'dim_calendar.csv'     INTO TABLE dim_calendar     FIELDS TERMINATED BY ',' IGNORE 1 LINES;
-- LOAD DATA LOCAL INFILE 'dim_tariff_tiers.csv' INTO TABLE dim_tariff_tiers FIELDS TERMINATED BY ',' IGNORE 1 LINES;
-- LOAD DATA LOCAL INFILE 'fact_hourly_load.csv' INTO TABLE fact_hourly_load FIELDS TERMINATED BY ',' IGNORE 1 LINES;

-- ---------------------------------------------------------------------
-- Analytical queries
-- Evening peak window = hour_id 19, 20, 21 (19:00 up to 22:00)
-- ---------------------------------------------------------------------

-- 1. Row counts and data-quality check
SELECT 'dim_calendar' AS table_name, COUNT(*) AS row_count FROM dim_calendar
UNION ALL SELECT 'dim_tariff_tiers', COUNT(*) FROM dim_tariff_tiers
UNION ALL SELECT 'fact_hourly_load', COUNT(*) FROM fact_hourly_load
UNION ALL SELECT 'imputed minutes inside fact_hourly_load', SUM(imputed_minutes_count) FROM fact_hourly_load;


-- 2. Headline KPIs: average load, evening peak (19:00-22:00) and surge
WITH overall AS (
    SELECT AVG(global_active_power_kw) AS avg_kw
    FROM fact_hourly_load
),
evening AS (
    SELECT AVG(global_active_power_kw) AS evening_kw
    FROM fact_hourly_load
    WHERE hour_id BETWEEN 19 AND 21          -- 19:00 up to 22:00
)
SELECT ROUND(o.avg_kw, 2)                          AS daily_avg_load_kw,
       ROUND(e.evening_kw, 2)                      AS evening_peak_kw,
       ROUND(100 * (e.evening_kw / o.avg_kw - 1), 1) AS evening_surge_pct
FROM overall o CROSS JOIN evening e;


-- 3. Hours ranked by average demand (DENSE_RANK)
WITH hour_profile AS (
    SELECT t.hour_id, t.hour_label, t.tou_tier_label,
           AVG(f.global_active_power_kw) AS avg_kw
    FROM fact_hourly_load f
    JOIN dim_tariff_tiers t ON t.hour_id = f.hour_id
    GROUP BY t.hour_id, t.hour_label, t.tou_tier_label
)
SELECT hour_label, tou_tier_label,
       ROUND(avg_kw, 3) AS avg_kw,
       DENSE_RANK() OVER (ORDER BY avg_kw DESC) AS demand_rank
FROM hour_profile
ORDER BY demand_rank
LIMIT 8;


-- 4. Weekday vs weekend profile by time-of-use tier
SELECT t.tou_tier_label,
       ROUND(AVG(CASE WHEN c.day_type_label = 'Weekday' THEN f.global_active_power_kw END), 3) AS weekday_avg_kw,
       ROUND(AVG(CASE WHEN c.day_type_label = 'Weekend' THEN f.global_active_power_kw END), 3) AS weekend_avg_kw
FROM fact_hourly_load f
JOIN dim_calendar     c ON c.date_id = f.date_id
JOIN dim_tariff_tiers t ON t.hour_id = f.hour_id
GROUP BY t.tou_tier_label
ORDER BY MIN(t.hour_id);


-- 5. Seasonal profile: winter vs summer trough
WITH season_avg AS (
    SELECT c.season_label, AVG(f.global_active_power_kw) AS avg_kw
    FROM fact_hourly_load f
    JOIN dim_calendar c ON c.date_id = f.date_id
    GROUP BY c.season_label
)
SELECT season_label,
       ROUND(avg_kw, 3) AS avg_kw,
       ROUND(100 * (avg_kw / (SELECT avg_kw FROM season_avg WHERE season_label = 'Summer') - 1), 1) AS pct_above_summer,
       DENSE_RANK() OVER (ORDER BY avg_kw DESC) AS season_rank
FROM season_avg
ORDER BY season_rank;


-- 6. Sub-metering shares of total energy
WITH totals AS (
    SELECT SUM(sub_metering_1_kitchen_wh) AS kitchen,
           SUM(sub_metering_2_laundry_wh) AS laundry,
           SUM(sub_metering_3_hvac_wh)    AS hvac,
           SUM(unmetered_other_wh)        AS other
    FROM fact_hourly_load
)
SELECT ROUND(100.0 * kitchen / (kitchen + laundry + hvac + other), 1) AS kitchen_pct,
       ROUND(100.0 * laundry / (kitchen + laundry + hvac + other), 1) AS laundry_pct,
       ROUND(100.0 * hvac    / (kitchen + laundry + hvac + other), 1) AS water_heater_ac_pct,
       ROUND(100.0 * other   / (kitchen + laundry + hvac + other), 1) AS unmetered_pct,
       ROUND(100.0 * hvac    / (kitchen + laundry + hvac), 1)         AS hvac_share_of_metered_pct
FROM totals;


-- 7. Sub-metering mix inside the evening window vs the rest of the day
SELECT CASE WHEN hour_id BETWEEN 19 AND 21 THEN 'Evening 19:00-22:00' ELSE 'Other hours' END AS window_label,
       ROUND(100.0 * SUM(sub_metering_1_kitchen_wh) / SUM(sub_metering_1_kitchen_wh + sub_metering_2_laundry_wh + sub_metering_3_hvac_wh + unmetered_other_wh), 1) AS kitchen_pct,
       ROUND(100.0 * SUM(sub_metering_2_laundry_wh) / SUM(sub_metering_1_kitchen_wh + sub_metering_2_laundry_wh + sub_metering_3_hvac_wh + unmetered_other_wh), 1) AS laundry_pct,
       ROUND(100.0 * SUM(sub_metering_3_hvac_wh)    / SUM(sub_metering_1_kitchen_wh + sub_metering_2_laundry_wh + sub_metering_3_hvac_wh + unmetered_other_wh), 1) AS hvac_pct,
       ROUND(100.0 * SUM(unmetered_other_wh)        / SUM(sub_metering_1_kitchen_wh + sub_metering_2_laundry_wh + sub_metering_3_hvac_wh + unmetered_other_wh), 1) AS unmetered_pct
FROM fact_hourly_load
GROUP BY CASE WHEN hour_id BETWEEN 19 AND 21 THEN 'Evening 19:00-22:00' ELSE 'Other hours' END;


-- 8. Daily load factor with 7-day rolling average and running yearly energy
WITH daily AS (
    SELECT c.date_id, c.full_date, c.year,
           AVG(f.global_active_power_kw) AS avg_kw,
           MAX(f.global_active_power_kw) AS peak_kw,
           SUM(f.global_active_power_kw) AS day_kwh
    FROM fact_hourly_load f
    JOIN dim_calendar c ON c.date_id = f.date_id
    GROUP BY c.date_id, c.full_date, c.year
)
SELECT full_date,
       ROUND(avg_kw, 3) AS avg_kw,
       ROUND(100 * avg_kw / peak_kw, 1) AS load_factor_pct,
       ROUND(AVG(avg_kw) OVER (ORDER BY full_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 3) AS rolling_7d_avg_kw,
       ROUND(SUM(day_kwh) OVER (PARTITION BY year ORDER BY full_date), 1) AS year_to_date_kwh
FROM daily
WHERE full_date >= '2009-01-01'
ORDER BY full_date
LIMIT 10;


-- 9. Rolling 24-hour average load (one January 2009 day)
WITH january AS (
    SELECT hourly_id, `timestamp`, global_active_power_kw
    FROM fact_hourly_load
    WHERE date_id BETWEEN 20081231 AND 20090102
),
rolled AS (
    SELECT `timestamp`, global_active_power_kw,
           AVG(global_active_power_kw) OVER (ORDER BY hourly_id ROWS BETWEEN 23 PRECEDING AND CURRENT ROW) AS rolling_24h_avg_kw
    FROM january
)
SELECT `timestamp`,
       ROUND(global_active_power_kw, 3) AS load_kw,
       ROUND(rolling_24h_avg_kw, 3)     AS rolling_24h_avg_kw
FROM rolled
WHERE `timestamp` >= '2009-01-01 18:00:00' AND `timestamp` <= '2009-01-01 23:00:00'
ORDER BY `timestamp`;


-- 10. Top 3 peak-demand days per year (DENSE_RANK with PARTITION BY)
WITH daily AS (
    SELECT c.full_date, c.year,
           MAX(f.global_active_power_kw) AS peak_kw,
           AVG(f.global_active_power_kw) AS avg_kw
    FROM fact_hourly_load f
    JOIN dim_calendar c ON c.date_id = f.date_id
    GROUP BY c.full_date, c.year
),
ranked AS (
    SELECT year, full_date, peak_kw, avg_kw,
           DENSE_RANK() OVER (PARTITION BY year ORDER BY peak_kw DESC) AS peak_rank
    FROM daily
)
SELECT year, full_date, ROUND(peak_kw, 2) AS peak_kw, ROUND(avg_kw, 2) AS avg_kw, peak_rank
FROM ranked
WHERE peak_rank <= 3
ORDER BY year, peak_rank;


-- 11. Average daily load factor by season
WITH daily AS (
    SELECT c.date_id, c.season_label,
           AVG(f.global_active_power_kw) AS avg_kw,
           MAX(f.global_active_power_kw) AS peak_kw
    FROM fact_hourly_load f
    JOIN dim_calendar c ON c.date_id = f.date_id
    GROUP BY c.date_id, c.season_label
)
SELECT season_label,
       COUNT(*) AS days,
       ROUND(100 * AVG(avg_kw / peak_kw), 1) AS avg_load_factor_pct
FROM daily
GROUP BY season_label
ORDER BY avg_load_factor_pct DESC;


-- 12. Load-shifting scenario: evening peak and tariff cost before vs after
WITH scenario AS (
    SELECT AVG(CASE WHEN f.hour_id BETWEEN 19 AND 21 THEN f.global_active_power_kw END) AS evening_before_kw,
           AVG(CASE WHEN f.hour_id BETWEEN 19 AND 21 THEN f.shifted_load_kw END)        AS evening_after_kw,
           SUM(f.global_active_power_kw * t.tariff_rate_usd_kwh) AS cost_before_usd,
           SUM(f.shifted_load_kw        * t.tariff_rate_usd_kwh) AS cost_after_usd
    FROM fact_hourly_load f
    JOIN dim_tariff_tiers t ON t.hour_id = f.hour_id
)
SELECT ROUND(evening_before_kw, 2) AS evening_peak_before_kw,
       ROUND(evening_after_kw, 2)  AS evening_peak_after_kw,
       ROUND(100 * (1 - evening_after_kw / evening_before_kw), 1) AS peak_reduction_pct,
       ROUND(cost_before_usd, 0) AS tariff_cost_before_usd,
       ROUND(cost_after_usd, 0)  AS tariff_cost_after_usd,
       ROUND(100 * (1 - cost_after_usd / cost_before_usd), 1) AS cost_saving_pct
FROM scenario;
