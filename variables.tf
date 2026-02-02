variable "domain" {
  type = string
}

variable "websites" {
  type = list(string)
}

variable "github_owner_id" {
  type = number
}

variable "terraform_workspace_id" {
  type = string
}
