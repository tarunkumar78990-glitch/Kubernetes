# Remote state in GCS. Locking is automatic on GCS (object generations) -
# there is no DynamoDB equivalent to configure, unlike AWS.
#
# Replace the bucket name with the one you created in Part 1 Section D.

terraform {
  backend "gcs" {
    bucket = "full-kubernetas-tfstate"
    prefix = "env/dev"
  }
}
