# A cost budget is the cheapest guardrail available and the one most easily forgotten, so it is
# provisioned with the state bucket rather than left as a console click.
#
# It alerts; it does not cap. AWS has no hard spend limit, which is why the design also relies on
# small task sizes, no NAT gateway and a verified teardown path rather than on this alarm.

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset(var.budget_alert_thresholds)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }

  # Forecast alerts arrive while there is still time to act; actual-spend alerts only confirm the
  # money is already gone.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
