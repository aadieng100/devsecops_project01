variable "image_tag" {
  type        = string
  description = "The target container image tag inside GHCR"
}

variable "github_token" {
  type        = string
  description = "Short-lived automation token to pull the private image"
  sensitive   = true
}

variable "github_actor" {
  type        = string
  description = "The GitHub username triggering the execution"
}