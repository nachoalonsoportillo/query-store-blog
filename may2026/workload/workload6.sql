select
 sum(l_extendedprice* (1 - l_discount)) as REVENUE
from
 LINEITEM,
 PART
where
 (
  P_PARTKEY = L_PARTKEY
  and P_BRAND = N'Brand#24'
  and P_CONTAINER in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
  and L_QUANTITY >= 7 and L_QUANTITY <= 7 + 10
  and P_SIZE between 1 and 5
  and L_SHIPMODE in ('AIR', 'AIR REG')
  and L_SHIPINSTRUCT = 'DELIVER IN PERSON'
 )
 or
 (
  P_PARTKEY = L_PARTKEY
  and P_BRAND = N'Brand#51'
  and P_CONTAINER in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
  and L_QUANTITY >= 15 and L_QUANTITY <= 15 + 10
  and P_SIZE between 1 and 10
  and L_SHIPMODE in ('AIR', 'AIR REG')
  and L_SHIPINSTRUCT = 'DELIVER IN PERSON'
 )
 or
 (
  P_PARTKEY = L_PARTKEY
  and P_BRAND = N'3'
  and P_CONTAINER in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
  and L_QUANTITY >= 27 and L_QUANTITY <= 27 + 10
  and P_SIZE between 1 and 15
  and L_SHIPMODE in ('AIR', 'AIR REG')
  and L_SHIPINSTRUCT = 'DELIVER IN PERSON'
 );
