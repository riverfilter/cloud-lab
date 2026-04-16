# Remote state backend.
#
# Uncomment and fill in once an S3 bucket + DynamoDB lock table exist. The
# bucket MUST have versioning + default encryption enabled. Prefer a
# customer-managed KMS key if this account is subject to compliance
# controls.
#
# Create the bucket and lock table out-of-band (chicken-and-egg with
# Terraform-managed state):
#
#   aws s3api create-bucket --bucket <bucket> --region <region> \
#     --create-bucket-configuration LocationConstraint=<region>
#   aws s3api put-bucket-versioning --bucket <bucket> \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket <bucket> \
#     --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws dynamodb create-table --table-name <lock-table> \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region <region>
#
# terraform {
#   backend "s3" {
#     bucket         = "REPLACE-ME-tfstate-bucket"
#     key            = "aws-eks-tf/sec-lab.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "REPLACE-ME-tfstate-locks"
#     encrypt        = true
#   }
# }
