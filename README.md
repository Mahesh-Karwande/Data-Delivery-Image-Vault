# Enterprise Data Delivery Image Vault

## Project Overview
A highly available, cloud-native image repository architected on AWS. This project demonstrates end-to-end infrastructure automation and full-stack application deployment, prioritizing cost-efficiency and optimized data storage routing.

## Architecture & Technology Stack
* **Infrastructure as Code (IaC):** Terraform (VPC, Subnets, Security Groups, Route 53, ACM, ALB, ASG).
* **Backend Framework:** Python / Flask.
* **Database (Metadata):** Amazon RDS (MySQL) - Captures user context, timestamps, file sizes, and S3 linkage.
* **Storage Layer (Physical Assets):** Amazon S3 - Secured via custom IAM roles and restrictive bucket policies with a 30-day automated lifecycle cleanup rule.
* **Shared File System:** Amazon EFS - Ensures codebase persistence across auto-scaling EC2 instances.

## Key Engineering Highlights
* **Automated Provisioning:** 100% of the AWS infrastructure is deployed and managed via Terraform state.
* **Cost Optimization:** Refactored initial multi-AZ enterprise architecture into a streamlined public-subnet deployment, eliminating NAT Gateway overhead while preserving strict Security Group isolations.
* **Decoupled Data Flow:** Physical large-binary assets are routed directly to S3 to preserve compute bandwidth, while structured metadata is logged to RDS for rapid front-end querying.

## Deployment Instructions
1. Initialize infrastructure: `terraform init` -> `terraform apply`.
2. Configure RDS MySQL tables using the provided schema.
3. Update `app.py` with environment-specific S3 bucket names and RDS endpoints.
4. Launch the Flask server on the target EC2 instance.

## Turn Off Block public access (bucket settings)
* **and use below code** in Bucket policy

`{`
    `"Version": "2012-10-17",`
    ` "Statement": [`
        `{`
            `"Sid": "PublicReadGetObject",`
            `"Effect": "Allow",`
            `"Principal": "*",`
            `"Action": "s3:GetObject",`
            `"Resource": "arn:aws:s3:::user-pictures-bucket-20260621053341019000000003/*"`
        `}`
    `]`
`}`
