# Security

## Reporting a Vulnerability

If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public GitHub issue.

## Supported Versions

Only the latest version of this project is currently being supported with security updates.

## Security Posture

### IAM Permissions

This project uses IAM roles with specific permissions. In production environments:
- Follow the principle of least privilege by scoping down the permissions listed in the README
- Consider using AWS Organizations' Service Control Policies (SCPs) to further restrict access
- Regularly audit IAM roles and permissions

### Network Security

The deployed EKS cluster:
- Should be placed in private subnets for production use
- Should have Network Policies enabled to restrict pod-to-pod communication
- Should implement proper security groups for node access

### Secret Management

- GitLab Runner registration tokens should be stored securely
- Consider using AWS Secrets Manager or Parameter Store instead of the `custom.json` file for production deployments
- Do not commit sensitive credentials to version control

### Container Security

- The GitLab Runner image is updated regularly with security patches
- Consider implementing image scanning in your CI/CD pipeline
- Use Pod Security Standards to restrict pod privileges

## Security Controls in This Project

1. HTTPS for all external communications
2. Proper RBAC for Kubernetes service accounts
3. Resource quotas to prevent DoS attacks
4. Health checks for detecting runner malfunctions
5. OIDC for secure AWS resource access

## Additional Security Considerations

- Enable AWS CloudTrail and GuardDuty for monitoring and threat detection
- Configure proper logging and monitoring for EKS and GitLab Runner
- Deploy the solution in a dedicated AWS account for better isolation

## Updates and Patching

It's recommended to:
- Regularly update the EKS version to the latest supported version
- Keep the GitLab Runner chart updated to the latest version
- Apply security patches promptly
- Subscribe to AWS Security Bulletins