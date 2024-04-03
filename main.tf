# A TF project to create a redirector property
#
# it will:
# 1: add hostname to property
# 2: automatically request secure by default certificate
# 3: create new redirect behavior for that hostname
# 
# $ export AKAMAI_CLIENT_SECRET="your_secret"
# $ export AKAMAI_HOST="your_host"
# $ export AKAMAI_ACCESS_TOKEN="your_access_token"
# $ export AKAMAI_CLIENT_TOKEN="your_client_token"


# just use group_name to lookup our contract_id and group_id
# this will simplify our variables file as this contains contract and group id
# use the akamai cli "akamai pm lg" to find all your groups.
data "akamai_contract" "contract" {
  group_name = var.group_name
}

locals {
  # create a normal cpcode id, remove that cpc_ part
  cp_code_id = tonumber(trimprefix(resource.akamai_cp_code.cp_code.id, "cpc_"))

  # convert the list of maps to a map of maps with entry.hostname as key of the map
  # this map of maps will be fed into our EdgeDNS module to create the CNAME records.
  dv_records = { for entry in resource.akamai_property.aka_property.hostnames[*].cert_status[0] : entry.hostname => entry }
}

# for the demo don't create cpcode's over and over again, just reuse existing one
# if cpcode already existst it will take the existing one.
resource "akamai_cp_code" "cp_code" {
  name        = var.cpcode
  contract_id = data.akamai_contract.contract.id
  group_id    = data.akamai_contract.contract.group_id
  product_id  = lookup(var.aka_products, lower(var.product_name))
}

# we're just going to use one edgehostname
# no need to create separate edgehostname per property hostname
resource "akamai_edge_hostname" "aka_edge" {

  product_id  = resource.akamai_cp_code.cp_code.product_id
  contract_id = data.akamai_contract.contract.id
  group_id    = data.akamai_contract.contract.group_id
  ip_behavior = var.ip_behavior

  # edgehostname based on hostname + network(FF/ESSL)
  edge_hostname = "${var.hostname}.${var.domain_suffix}"
}

# our dedicated redirect property. 
resource "akamai_property" "aka_property" {
  name        = var.hostname
  contract_id = data.akamai_contract.contract.id
  group_id    = data.akamai_contract.contract.group_id
  product_id  = resource.akamai_cp_code.cp_code.product_id

  # our dynamic hostname part using secure by default certs (SBD)
  # hostname is the key from our map, target edge hostname is always the same
  dynamic "hostnames" {
    for_each = var.hostnames
    content {
      cname_from             = hostnames.key
      cname_to               = resource.akamai_edge_hostname.aka_edge.edge_hostname
      cert_provisioning_type = "DEFAULT"
    }
  }

  # template file will create some dynamic json output for the redirect part of the rules file
  # in the template file using jsonencode() to create some proper json automatically.
  # because using jsonencode()we can use normal terraform expression syntax instead of using template syntax
  # https://developer.hashicorp.com/terraform/language/functions/templatefile
  # a for loop using ${var} and non-for loop just use var name like cp_code_id for example
  rules = templatefile("templates/rules.tftpl", { hostnames = var.hostnames, cp_code_id = local.cp_code_id, cp_code_name = var.cpcode })
}

# let's activate this property on staging
# staging will always use latest version but when useing on production a version number should be provided.
resource "akamai_property_activation" "aka_staging" {
  property_id = resource.akamai_property.aka_property.id
  contact     = [var.email]
  version     = resource.akamai_property.aka_property.latest_version
  network     = "STAGING"
  note        = "Action triggered by Terraform."

  # set to true otherwise activation will fail
  auto_acknowledge_rule_warnings = true
}