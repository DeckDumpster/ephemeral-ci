import * as cdk from 'aws-cdk-lib';
import { SpillStack } from '../lib/spill-stack';
import { BootstrapIdentityStack } from '../lib/bootstrap-identity-stack';

const app = new cdk.App();
new SpillStack(app, 'EphemeralCiSpill', {
  env: {
    account: '189923011121',
    region: 'us-west-2',
  },
});
new BootstrapIdentityStack(app, 'BootstrapIdentity', {
  env: {
    account: '189923011121',
    region: 'us-west-2',
  },
  // This stack deploys before cdk bootstrap has run. Without this flag the
  // default synthesiser emits a BootstrapVersion parameter and a
  // CheckBootstrapVersion rule that read /cdk-bootstrap/hnb659fds/version,
  // causing the CloudFormation console to refuse the deploy.
  synthesizer: new cdk.DefaultStackSynthesizer({
    generateBootstrapVersionRule: false,
  }),
});
