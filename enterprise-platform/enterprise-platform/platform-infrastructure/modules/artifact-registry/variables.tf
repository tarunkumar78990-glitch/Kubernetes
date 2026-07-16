variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env" {
  type = string
}

variable "repo_name" {
  type    = string
  default = "microservices"
}

# NOTE ON THE TYPE: these are map(string), not list(string).
#
# Terraform requires `for_each` KEYS to be known at plan time. The member
# strings contain a service-account email that does not exist until apply, so
# `for_each = toset(var.writer_members)` fails with "Invalid for_each
# argument" -- toset() makes the value itself the key.
#
# A map fixes it: the key is a static literal, the value may be apply-time.
# See environments/*/main.tf for how the caller passes these.
#
# WARNING, learned the hard way: do NOT put an example containing a dollar-brace
# interpolation inside a heredoc `description`. Terraform interpolates heredocs,
# so a documentation example becomes live code and fails with:
#     Error: Variables not allowed
#     Error: Unsuitable value type -- value must be known
# Variable descriptions must be constant. Keep examples in # comments like this
# one, or escape them by doubling the dollar sign.

variable "writer_members" {
  description = "Who can push images. Map of static key to IAM member string."
  type        = map(string)
  default     = {}
}

variable "reader_members" {
  description = "Who can pull images. Map of static key to IAM member string."
  type        = map(string)
  default     = {}
}

variable "keep_recent_count" {
  type    = number
  default = 20
}
