# Encoding: utf-8
#
# Cookbook Name:: glpi
# Recipe:: default
#
# Copyright 2014, Mariani Lucas
# Copyright 2014, Cheveste Martin
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
include_recipe 'apache2::default'
include_recipe 'apache2::mod_php5'
include_recipe 'mysql::server'
include_recipe 'php::default'
include_recipe 'subversion::default'
include_recipe 'database::mysql'

password = glpi_encrypt(node[:glpi][:ad][:bindpassword])

%w(php-ldap php-imap php-mysql php-mbstring).each do |pkg|
  package pkg do
    action :install
  end
end

directory node[:glpi][:path] do
  owner node[:apache][:user]
  group node[:apache][:group]
  action :create
end

subversion 'glpi_source' do
  repository "#{node[:glpi][:url]}/GLPI_#{node[:glpi][:version]}"
  revision 'HEAD'
  destination node[:glpi][:path]
  user node[:apache][:user]
  group node[:apache][:group]
  action :checkout
end

mysql_connection_info = {
  :host     => 'localhost',
  :username => 'root',
  :password => node[:mysql][:server_root_password]
}

mysql_database node[:glpi][:db_name] do
  connection mysql_connection_info
  action :create
end

mysql_database_user node[:glpi][:db_user] do
  connection mysql_connection_info
  password node[:glpi][:db_password]
  database_name node[:glpi][:db_name]
  host '%'
  privileges [:all]
  action :grant
end

script 'glpi_schema' do
  interpreter 'bash'
  user 'root'
  cwd "#{node[:glpi][:path]}/install/mysql"
  code <<-EOH
       mysql #{node[:glpi][:db_name]} < glpi-0.84.4-empty.sql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]}
  EOH
  not_if "mysql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]} #{node[:glpi][:db_name]} -e \"SELECT version FROM glpi_configs\" | grep #{node[:glpi][:version]} -ci "
end

mysql_database 'glpi_password' do
  connection mysql_connection_info
  database_name node[:glpi][:db_name]
  sql "UPDATE glpi_users SET password = MD5(\'#{node[:glpi][:glpi_pass]}\') WHERE name IN (\'glpi\',\'post-only\',\'tech\',\'normal\');"
  action :query
  only_if "mysql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]} #{node[:glpi][:db_name]} -e \"SELECT password FROM glpi_users\" | grep 0915bd0a5c6e56d8f38ca2b390857d4949073f41 -ci "
end

mysql_database 'glpi_AD' do
  connection mysql_connection_info
  database_name node[:glpi][:db_name]
  action :query
  if node[:glpi][:ad][:enable]
    sql "INSERT INTO `glpi_authldaps` (name, host, basedn, rootdn, port, login_field, group_field, group_search_type, email1_field, realname_field, firstname_field, phone_field, phone2_field, mobile_field, comment_field, use_dn, deref_option, title_field, entity_field, entity_condition, date_mod, is_default, is_active, rootdn_passwd, registration_number_field) VALUES ('#{node[:glpi][:ad][:domain]}','#{node[:glpi][:ad][:pdc]}','#{node[:glpi][:ad][:basedn]}','#{node[:glpi][:ad][:binduser]}',#{node[:glpi][:ad][:port]},'samaccountname','memberof',2,'mail','sn','givenname','telephonenumber','othertelephone','mobile','info',1,0,'title','ou','(objectclass=organizationalUnit)',now(),1,1,'#{password}','employeenumber');"
    not_if "mysql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]} #{node[:glpi][:db_name]} -e \"SELECT * FROM glpi_authldaps\" | grep #{node[:glpi][:ad][:domain]}"
  else
    sql "DELETE FROM `glpi_authldaps` WHERE name = '#{node[:glpi][:ad][:domain]}';"
    only_if "mysql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]} #{node[:glpi][:db_name]} -e \"SELECT * FROM glpi_authldaps\" | grep #{node[:glpi][:ad][:domain]}"
  end
end

node[:glpi][:mailcollector].each_pair do |name, mail|
  password = glpi_encrypt(mail[:password])
  mysql_database "glpi_mail_#{name}" do
    connection mysql_connection_info
    database_name node[:glpi][:db_name]
    sql "INSERT INTO `glpi_mailcollectors` (name, host, login, filesize_max, is_active, date_mod, passwd) VALUES ('#{name}','#{mail[:host]}','#{mail[:login]}','#{mail[:filesize_max] * 1_048_576}',1,now(),'#{password}');"
    not_if "mysql --user=#{node[:glpi][:db_user]} --password=#{node[:glpi][:db_password]} #{node[:glpi][:db_name]} -e \"SELECT * FROM glpi_mailcollectors\" | grep #{name}"
    action :query
  end
end

template "#{node[:apache][:dir]}/sites-available/glpi.conf" do
  source 'glpi.conf.erb'
  owner 'root'
  group 'root'
  mode '0644'
  notifies :restart, 'service[apache2]', :delayed
end

template "#{node[:glpi][:path]}/config/config_db.php" do
  source 'config_db.php.erb'
  owner 'root'
  group 'root'
  mode '0644'
  notifies :restart, 'service[apache2]', :delayed
end

file "#{node[:glpi][:path]}/install/install.php" do
  action :delete
  owner 'root'
  group 'root'
  mode '0644'
end

apache_site 'glpi.conf' do
  enable site_enabled
end

include_recipe 'glpi::theme'
