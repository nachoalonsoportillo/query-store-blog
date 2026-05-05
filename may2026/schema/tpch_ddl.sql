
CREATE TABLE customer(
	C_CustKey int NOT NULL,
	C_Name varchar(64) NULL,
	C_Address varchar(64) NULL,
	C_NationKey int NULL,
	C_Phone varchar(64) NULL,
	C_AcctBal decimal(13, 2) NULL,
	C_MktSegment varchar(64) NULL,
	C_Comment varchar(120) NULL
);

CREATE TABLE lineitem(
	L_OrderKey int NULL,
	L_PartKey int NULL,
	L_SuppKey int NULL,
	L_LineNumber int NULL,
	L_Quantity int NULL,
	L_ExtendedPrice decimal(13, 2) NULL,
	L_Discount decimal(13, 2) NULL,
	L_Tax decimal(13, 2) NULL,
	L_ReturnFlag varchar(64) NULL,
	L_LineStatus varchar(64) NULL,
	L_ShipDate timestamp NULL,
	L_CommitDate timestamp NULL,
	L_ReceiptDate timestamp NULL,
	L_ShipInstruct varchar(64) NULL,
	L_ShipMode varchar(64) NULL,
	L_Comment varchar(64) NULL
);


CREATE TABLE nation(
	N_NationKey int NULL,
	N_Name varchar(64) NULL,
	N_RegionKey int NULL,
	N_Comment varchar(160) NULL
);

CREATE TABLE orders(
	O_OrderKey int NULL,
	O_CustKey int NULL,
	O_OrderStatus varchar(64) NULL,
	O_TotalPrice decimal(13, 2) NULL,
	O_OrderDate timestamp NULL,
	O_OrderPriority varchar(15) NULL,
	O_Clerk varchar(64) NULL,
	O_ShipPriority int NULL,
	O_Comment varchar(80) NULL
);

CREATE TABLE part(
	P_PartKey int NULL,
	P_Name varchar(64) NULL,
	P_Mfgr varchar(64) NULL,
	P_Brand varchar(64) NULL,
	P_Type varchar(64) NULL,
	P_Size int NULL,
	P_Container varchar(64) NULL,
	P_RetailPrice decimal(13, 2) NULL,
	P_Comment varchar(64) NULL
);

CREATE TABLE partsupp(
	PS_PartKey int NULL,
	PS_SuppKey int NULL,
	PS_AvailQty int NULL,
	PS_SupplyCost decimal(13, 2) NULL,
	PS_Comment varchar(200) NULL
);

CREATE TABLE region(
	R_RegionKey int NULL,
	R_Name varchar(64) NULL,
	R_Comment varchar(160) NULL
);

CREATE TABLE supplier(
	S_SuppKey int NULL,
	S_Name varchar(64) NULL,
	S_Address varchar(64) NULL,
	S_NationKey int NULL,
	S_Phone varchar(18) NULL,
	S_AcctBal decimal(13, 2) NULL,
	S_Comment varchar(105) NULL
);

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
