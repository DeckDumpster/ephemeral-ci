import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';

export interface BackupStackProps extends cdk.StackProps {
  /** Name of the existing role the Concierge runs as; granted read on the writer-key secret only. */
  readonly conciergeRoleName?: string;
}

/**
 * Off-box backup target for Spira store snapshots (sp-vrnpql): a private,
 * versioned bucket and a put-only writer key (law-off-box-backups-are-private-and-write-only).
 */
export class BackupStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: BackupStackProps) {
    super(scope, id, props);

    const bucket = new s3.Bucket(this, 'SnapshotBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        { noncurrentVersionExpiration: cdk.Duration.days(30) },
      ],
    });

    const writer = new iam.User(this, 'Writer');
    writer.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:PutObject'],
        resources: [bucket.arnForObjects('spira/*')],
      }),
    );

    const key = new iam.CfnAccessKey(this, 'WriterKey', { userName: writer.userName });

    const secret = new secretsmanager.Secret(this, 'WriterKeySecret', {
      description: 'Put-only access key for the Spira snapshot bucket (lc-backup.env)',
      secretObjectValue: {
        AWS_ACCESS_KEY_ID: cdk.SecretValue.unsafePlainText(key.ref),
        AWS_SECRET_ACCESS_KEY: cdk.SecretValue.resourceAttribute(key.attrSecretAccessKey),
        LC_BACKUP_BUCKET: cdk.SecretValue.unsafePlainText(bucket.bucketName),
      },
    });

    const concierge = iam.Role.fromRoleName(
      this,
      'ConciergeRole',
      props?.conciergeRoleName ?? 'spira-concierge',
    );
    secret.grantRead(concierge);

    new cdk.CfnOutput(this, 'BucketName', { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'WriterSecretArn', { value: secret.secretArn });
  }
}
