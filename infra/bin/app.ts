import * as cdk from 'aws-cdk-lib';
import { TerraformBootstrapStack } from '../lib/terraform-bootstrap-stack';

// TerraformBootstrap is the only stack CDK still deploys (it provides what
// Terraform needs). Everything else is Terraform, in infra/terraform.
const app = new cdk.App();
new TerraformBootstrapStack(app, 'TerraformBootstrap', {
  env: {
    account: '189923011121',
    region: 'us-west-2',
  },
});
