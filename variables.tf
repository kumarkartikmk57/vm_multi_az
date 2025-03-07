variable "project_id" {
  type = string
  default = "bigquery-demo-452006"
}
variable "instance_name" {
  type = string
}
variable "machine_type" {
  type = string
}
variable "zone" {
  type = string
  default = "europe-west1"
}
variable "region" {
  type = string
  default = "europe-west1"
}
variable "instance_count" {
  type = string
}
variable "service_account_email" {
  type = string
}
variable "dns_domain" {
  type = string
}
