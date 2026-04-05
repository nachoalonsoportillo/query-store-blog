CREATE OR REPLACE FUNCTION public.get_customer_data_with_mix_params(
    "nationKey" INT,
    nation_key INT,
    "mktSegment" VARCHAR,
    market_segment VARCHAR,
    "custLimit" INT,
    cust_limit INT,
    "sortOrder" VARCHAR,
    sort_order VARCHAR,
    "filterActive" BOOLEAN,
    filter_active BOOLEAN,
    "offsetRows" INT,
    offset_rows INT
)
RETURNS TABLE (
    C_CustKey INT,
    C_Name VARCHAR,
    C_AcctBal DECIMAL,
    C_MktSegment VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        customer.C_CustKey,
        customer.C_Name,
        customer.C_AcctBal,
        customer.C_MktSegment
    FROM
        customer
    WHERE
        (customer.C_NationKey = "nationKey" AND (customer.C_NationKey >= ($2 - 1) OR customer.C_NationKey = nation_key))
        AND
        (customer.C_MktSegment = "mktSegment" OR customer.C_MktSegment = $4 OR customer.C_MktSegment = market_segment)
    GROUP BY
        customer.C_CustKey, customer.C_MktSegment, customer.C_Name, customer.C_AcctBal
    ORDER BY
        CASE WHEN "filterActive" = TRUE OR filter_active = TRUE THEN customer.C_CustKey END ASC,
        CASE WHEN "sortOrder" = 'DESC' OR $8 = 'DESC' THEN customer.C_MktSegment END DESC,
        CASE WHEN sort_order = 'ASC' OR $7 = 'ASC' THEN customer.C_MktSegment END ASC
    LIMIT 
        CASE WHEN "custLimit" > 0 THEN "custLimit" 
             WHEN $6 > 0 THEN cust_limit 
             ELSE 100 END
    OFFSET
        CASE WHEN "offsetRows" >= 0 THEN "offsetRows"
             WHEN $12 >= 0 THEN offset_rows
             ELSE 0 END;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_customer_data()
RETURNS TABLE (
    C_CustKey INT,
    C_Name VARCHAR,
    C_AcctBal DECIMAL,
    C_MktSegment VARCHAR
) AS $$
DECLARE
    nation_key INT;
    market_segment VARCHAR;
BEGIN
    -- Select C_NationKey and C_MktSegment into variables
    SELECT
        customer.C_NationKey,
        customer.C_MktSegment
    INTO
        nation_key,
        market_segment
    FROM
        customer
    order by random() limit 1;

    -- Call the get_customer_data_with_mix_params function using the variables
    RETURN QUERY
    SELECT * FROM get_customer_data_with_mix_params(
        nation_key,     -- "nationKey" (case sensitive)
        nation_key,     -- nation_key (case insensitive)
        market_segment, -- "mktSegment" (case sensitive) 
        market_segment, -- market_segment (case insensitive)
        50,            -- "custLimit" (case sensitive)
        100,           -- cust_limit (case insensitive)
        'DESC',        -- "sortOrder" (case sensitive)
        'ASC',         -- sort_order (case insensitive)
        TRUE,          -- "filterActive" (case sensitive)
        FALSE,         -- filter_active (case insensitive)
        5,             -- "offsetRows" (case sensitive)
        10             -- offset_rows (case insensitive)
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION query_nation(INT, INT, VARCHAR)
RETURNS TABLE (
    n_nationkey INT,
    n_name VARCHAR,
    n_regionkey INT,
    n_comment VARCHAR,
    nation_count BIGINT,
    max_regionkey INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        n.N_NationKey,
        n.N_Name,
        n.N_RegionKey,
        n.N_Comment,
        COUNT(*) AS nation_count,
        MAX(n.N_RegionKey) AS max_regionkey
    FROM
        nation n
    WHERE
        n.N_NationKey = $1 AND
        n.N_RegionKey = $2 AND
        length(n.N_Name) <= length($3)
    GROUP BY
        n.N_NationKey, n.N_Name, n.N_RegionKey, n.N_Comment
    ORDER BY
        n.N_NationKey, n.N_Name desc;
END;
$$ LANGUAGE plpgsql;
