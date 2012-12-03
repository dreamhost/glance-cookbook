#
# Cookbook Name:: glance
# Recipe:: api
#
# Copyright 2012, Rackspace US, Inc.
# Copyright 2012, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "osops-utils"
include_recipe "osops-utils::repo"

platform_options = node["glance"]["platform"]

#creates db and user
#returns connection info
#defined in osops-utils/libraries
mysql_info = create_db_and_user("mysql",
  node["glance"]["db"]["name"],
  node["glance"]["db"]["username"],
  node["glance"]["db"]["password"])

package "curl" do
  action :upgrade
end

package "python-keystone" do
  action :install
end

platform_options["glance_packages"].each do |pkg|
  package pkg do
    action :upgrade
  end
end

service "glance-api" do
  service_name platform_options["glance_api_service"]
  supports :status => true, :restart => true
  action :enable
end

directory "/etc/glance" do
  action :create
  group "glance"
  owner "glance"
  mode "0700"
end

# FIXME: seems like misfeature
template "/etc/glance/policy.json" do
  source "policy.json.erb"
  owner "root"
  group "root"
  mode "0644"
  notifies :restart, resources(:service => "glance-api"), :immediately
  not_if do
    File.exists?("/etc/glance/policy.json")
  end
end

rabbit_info = get_settings_by_role("rabbitmq-server", "rabbitmq") # FIXME: access

ks_admin_endpoint = get_access_endpoint("keystone", "keystone", "admin-api")
ks_service_endpoint = get_access_endpoint("keystone", "keystone","service-api")
keystone = get_settings_by_role("keystone", "keystone")
glance = get_settings_by_role("glance-api", "glance")

registry_endpoint = get_access_endpoint("glance-registry", "glance", "registry")
api_endpoint = get_bind_endpoint("glance", "api")

# Possible combinations of options here
# - default_store=file
#     * no other options required
# - default_store=swift
#     * if swift_store_auth_address is not defined
#         - default to local swift
#     * else if swift_store_auth_address is defined
#         - get swift_store_auth_address, swift_store_user, swift_store_key, and
#           swift_store_auth_version from the node attributes and use them to connect
#           to the swift compatible API service running elsewhere - possibly
#           Rackspace Cloud Files.
if glance["api"]["swift_store_auth_address"].nil?
  swift_store_auth_address="http://#{ks_admin_endpoint["host"]}:#{ks_service_endpoint["port"]}/v2.0"
  swift_store_user="#{glance["service_tenant_name"]}:#{glance["service_user"]}"
  swift_store_key=glance["service_pass"]
  swift_store_auth_version=2
else
  swift_store_auth_address=glance["api"]["swift_store_auth_address"]
  swift_store_user=glance["api"]["swift_store_user"]
  swift_store_key=glance["api"]["swift_store_key"]
  swift_store_auth_version=glance["api"]["swift_store_auth_version"]
end

# Only use the glance image cacher if we aren't using file for our backing store.
if glance["api"]["default_store"]=="file"
  glance_flavor="keystone"
else
  glance_flavor="keystone+cachemanagement"
end

template "/etc/glance/glance-api.conf" do
  source "glance-api.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    "db_ip_address" => mysql_info["bind_address"],
    "db_user" => node["glance"]["db"]["username"],
    "db_password" => node["glance"]["db"]["password"],
    "db_name" => node["glance"]["db"]["name"],
    "api_bind_address" => api_endpoint["host"],
    "api_bind_port" => api_endpoint["port"],
    "registry_ip_address" => registry_endpoint["host"],
    "registry_port" => registry_endpoint["port"],
    "use_syslog" => node["glance"]["syslog"]["use"],
    "log_facility" => node["glance"]["syslog"]["facility"],
    "rabbit_ipaddress" => IPManagement.get_ips_for_role("rabbitmq-server","nova",node)[0],    #FIXME!
    "default_store" => glance["api"]["default_store"],
    "glance_flavor" => glance_flavor,
    "swift_store_key" => swift_store_key,
    "swift_store_user" => swift_store_user,
    "swift_store_auth_address" => swift_store_auth_address,
    "swift_store_auth_version" => swift_store_auth_version,
    "swift_large_object_size" => glance["api"]["swift"]["store_large_object_size"],
    "swift_large_object_chunk_size" => glance["api"]["swift"]["store_large_object_chunk_size"],
    "swift_store_container" => glance["api"]["swift"]["store_container"],
    "keystone_api_ipaddress" => ks_admin_endpoint["host"],
    "keystone_service_port" => ks_service_endpoint["port"],
    "keystone_admin_port" => ks_admin_endpoint["port"],
    "keystone_admin_token" => keystone["admin_token"],
    "service_tenant_name" => node["glance"]["service_tenant_name"],
    "service_user" => node["glance"]["service_user"],
    "service_pass" => node["glance"]["service_pass"],
    "worker_count" => node["glance"]["services"]["api"]["worker_count"],
    "rbd_user" => glance["api"]["rbd"]["user"],
    "rbd_pool" => glance["api"]["rbd"]["pool"]
    )
  notifies :restart, resources(:service => "glance-api"), :immediately
end

template "/etc/glance/glance-cache.conf" do
  source "glance-cache.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    "registry_ip_address" => registry_endpoint["host"],
    "registry_port" => registry_endpoint["port"],
    "use_syslog" => node["glance"]["syslog"]["use"],
    "log_facility" => node["glance"]["syslog"]["facility"],
    "image_cache_max_size" => node["glance"]["api"]["cache"]["image_cache_max_size"],
    "keystone_api_ipaddress" => ks_admin_endpoint["host"],
    "keystone_service_port" => ks_service_endpoint["port"],
    "keystone_admin_port" => ks_admin_endpoint["port"],
    "keystone_admin_token" => keystone["admin_token"],
    "service_tenant_name" => node["glance"]["service_tenant_name"],
    "service_user" => node["glance"]["service_user"],
    "service_pass" => node["glance"]["service_pass"]
    )
  notifies :restart, resources(:service => "glance-api"), :delayed
end

template "/etc/glance/glance-scrubber.conf" do
  source "glance-scrubber.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    "registry_ip_address" => registry_endpoint["host"],
    "registry_port" => registry_endpoint["port"],
    "use_syslog" => node["glance"]["syslog"]["use"],
    "log_facility" => node["glance"]["syslog"]["facility"]
    )
end

# Configure glance-cache-pruner to run every 30 minutes
cron "glance-cache-pruner" do
  minute "*/30"
  command "/usr/bin/glance-cache-pruner"
end

# Configure glance-cache-cleaner to run at 00:01 everyday
cron "glance-cache-cleaner" do
  minute "01"
  hour "00"
  command "/usr/bin/glance-cache-cleaner"
end

# Register Image Service
keystone_register "Register Image Service" do
  auth_host ks_admin_endpoint["host"]
  auth_port ks_admin_endpoint["port"]
  auth_protocol ks_admin_endpoint["scheme"]
  api_ver ks_admin_endpoint["path"]
  auth_token keystone["admin_token"]
  service_name "glance"
  service_type "image"
  service_description "Glance Image Service"
  action :create_service
end

# Register Image Endpoint
keystone_register "Register Image Endpoint" do
  auth_host ks_admin_endpoint["host"]
  auth_port ks_admin_endpoint["port"]
  auth_protocol ks_admin_endpoint["scheme"]
  api_ver ks_admin_endpoint["path"]
  auth_token keystone["admin_token"]
  service_type "image"
  endpoint_region "RegionOne"
  endpoint_adminurl api_endpoint["uri"]
  endpoint_internalurl api_endpoint["uri"]
  endpoint_publicurl api_endpoint["uri"]
  action :create_endpoint
end

if node["glance"]["image_upload"]
  node["glance"]["images"].each do |img|
    Chef::Log.info("Checking to see if #{img.to_s}-image should be uploaded.")

    keystone_admin_user = keystone["admin_user"]
    keystone_admin_password = keystone["users"][keystone_admin_user]["password"]
    keystone_tenant = keystone["users"][keystone_admin_user]["default_tenant"]

    bash "default image setup for #{img.to_s}" do
      cwd "/tmp"
      user "root"
      environment ({"OS_USERNAME" => keystone_admin_user,
          "OS_PASSWORD" => keystone_admin_password,
          "OS_TENANT_NAME" => keystone_tenant,
          "OS_AUTH_URL" => ks_admin_endpoint["uri"]})
      code <<-EOH
          glance --silent-upload add name="#{img.to_s}-image" is_public=true container_format=bare disk_format=qcow2 location="#{node["glance"]["image"][img]}"
      EOH
      not_if "glance -f -I #{keystone_admin_user} -K #{keystone_admin_password} -T #{keystone_tenant} -N #{ks_admin_endpoint["uri"]} index | grep #{img.to_s}-image"
    end
  end
end
