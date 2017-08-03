# license patch on 3.2.17 or 3.2.18

## create

extract customer sources, then:
cust="customer_name"
cfg=$(grep configure ~/.cean_processone/pkg/$cust/ejabberd_$cust.pub | cut -d'"' -f2)
./configure $cfg
./rebar get-deps
license/build_license_installer.sh ${cust}_license 3.2.x_y YYYYMMDDN

this generates ${cust}_license.run in current directory
deliver that .run file to customer.

## apply

all ejabberd nodes should be running
execute the .run file, passing full path to ejabberdctl file:
./customer_license.run /opt/ejabberd-3.2.x_y/bin/ejabberdctl

# license patch on older 3.2.x (3.2.16 and lower)

## create

extract customer sources, then:
copy src/ejabberd_license.erl from 3.2.18 into src
copy license directory from 3.2.18 into current directory
then follow steps for 3.2.18 above.
deliver .run file to customer, and also ejabberd_license.beam

## apply

all ejabberd nodes should be running
copy ejabberd_license.beam in lib/ejabberd_customer-3.2.x_y/ebin on all nodes
execute the .run file, passing full path to ejabberdctl file:
./customer_license.run /opt/ejabberd-3.2.x_y/bin/ejabberdctl

