import * as cdk from 'aws-cdk-lib';
import { SpillStack } from '../lib/spill-stack';

const app = new cdk.App();
new SpillStack(app, 'EphemeralCiSpill', {
  env: {
    account: '189923011121',
    region: 'us-west-2',
  },
});
