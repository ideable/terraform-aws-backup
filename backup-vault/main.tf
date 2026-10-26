resource "aws_kms_key" "primary_key" {
  description         = "Primary backup vault key"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.key.json
}

data "aws_iam_policy_document" "key" {
  statement {
    sid = "AllowAdmin"
    not_actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*"
    ]
    resources = ["*"]
    principals {
      identifiers = local.admin_principals
      type        = "AWS"
    }
  }
  // Copies of resources not fully managed by AWS Backup (EBS, EC2/AMI) are re-encrypted
  // with this key by the backup role itself, not through a grant like RDS or EFS.
  // Same scoping as the AWS managed aws/ebs key: callers from the allowed accounts, only through EC2 or AWS Backup.
  statement {
    sid = "AllowUseThroughEc2AndBackup"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*"
    ]
    resources = ["*"]
    principals {
      identifiers = ["*"]
      type        = "AWS"
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = local.key_user_account_ids
    }
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values = [
        "ec2.*.amazonaws.com",
        "backup.*.amazonaws.com"
      ]
    }
  }
}

resource "aws_backup_vault" "account_vault" {

  name          = var.vault_name
  kms_key_arn   = aws_kms_key.primary_key.arn
  force_destroy = var.force_destroy
}

data "aws_iam_policy_document" "this" {
  statement {
    sid = "allowBackupIntoVault"

    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = local.admin_principals
    }

    actions = [
      "backup:DescribeBackupVault",
      "backup:DeleteBackupVault",
      "backup:PutBackupVaultAccessPolicy",
      "backup:DeleteBackupVaultAccessPolicy",
      "backup:GetBackupVaultAccessPolicy",
      "backup:StartBackupJob",
      "backup:GetBackupVaultNotifications",
      "backup:PutBackupVaultNotifications",
    ]

    resources = [
      aws_backup_vault.account_vault.arn,
    ]
  }
  statement {
    sid = "allowBackupCopyIntoVault"

    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "backup:CopyIntoBackupVault",
    ]

    resources = [
      aws_backup_vault.account_vault.arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [local.parent_org_id]
    }
  }
}

resource "aws_backup_vault_policy" "account_vault" {
  backup_vault_name = aws_backup_vault.account_vault.name
  policy            = data.aws_iam_policy_document.this.json
}

data "aws_caller_identity" "this" {}

data "aws_organizations_organization" "org" {}

locals {
  account_arn          = "arn:aws:iam::${local.account_id}:root"
  account_id           = data.aws_caller_identity.this.account_id
  admin_principals     = coalesce(var.admin_principals, [local.account_arn])
  key_user_account_ids = coalesce(var.key_user_account_ids, [local.account_id])
  parent_org_id        = data.aws_organizations_organization.org.id
}

