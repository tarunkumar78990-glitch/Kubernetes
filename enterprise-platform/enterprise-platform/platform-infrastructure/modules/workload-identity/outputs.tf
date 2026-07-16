output "service_account_emails" {
  description = "service name -> GSA email. Paste these into each service's KSA annotation."
  value       = { for k, v in google_service_account.svc : k => v.email }
}
