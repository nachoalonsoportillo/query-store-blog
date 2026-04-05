SELECT
   S_SUPPKEY
  ,S_NAME
  ,S_ADDRESS
  ,S_PHONE
  ,TOTAL_REVENUE
 FROM
   SUPPLIER
  ,(SELECT L_SUPPKEY AS SUPPLIER_NO , SUM(l_extendedprice*(1-l_discount)) AS TOTAL_REVENUE
   FROM LINEITEM
   WHERE   L_SHIPDATE >= DATE '1993-10-01'
   AND  L_SHIPDATE < DATE '1993-10-01' + INTERVAL '3' MONTH
   GROUP BY
     L_SUPPKEY)REVENUE
 WHERE
   S_SUPPKEY  = SUPPLIER_NO
 AND  TOTAL_REVENUE  =
         ( SELECT MAX(TOTAL_REVENUE) 
           FROM  ( SELECT L_SUPPKEY AS SUPPLIER_NO,
                            SUM(l_extendedprice*(1-l_discount)) AS TOTAL_REVENUE
                      FROM LINEITEM              
                                       WHERE L_SHIPDATE >= DATE '1993-10-01'
                       AND   L_SHIPDATE < DATE '1993-10-01' + INTERVAL '3' MONTH
                             GROUP BY L_SUPPKEY         
                           ) REVENUE
             )
 ORDER BY
   S_SUPPKEY;
