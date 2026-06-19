# ─── Auto-Shutdown at 08:00 UTC ───────────────────────────────────────────────
# Equivalent to Azure azurerm_dev_test_global_vm_shutdown_schedule
# Uses EventBridge Scheduler → EC2 StopInstances SDK call (no Lambda required)

resource "aws_iam_role" "scheduler" {
  name = "role-ec2-scheduler-${var.participant_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    owner = "sathish"
  }
}

resource "aws_iam_role_policy" "scheduler_stop_ec2" {
  name = "policy-ec2-stop"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ec2:StopInstances"]
      Resource = [
        aws_instance.app.arn,
        aws_instance.db.arn,
        aws_instance.win.arn
      ]
    }]
  })
}

# App VM — stop at 08:00 UTC daily
resource "aws_scheduler_schedule" "shutdown_app" {
  name       = "shutdown-app-${var.participant_name}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 8 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      InstanceIds = [aws_instance.app.id]
    })
  }
}

# DB VM — stop at 08:00 UTC daily
resource "aws_scheduler_schedule" "shutdown_db" {
  name       = "shutdown-db-${var.participant_name}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 8 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      InstanceIds = [aws_instance.db.id]
    })
  }
}

# Windows VM — stop at 08:00 UTC daily
resource "aws_scheduler_schedule" "shutdown_win" {
  name       = "shutdown-win-${var.participant_name}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 8 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      InstanceIds = [aws_instance.win.id]
    })
  }
}
