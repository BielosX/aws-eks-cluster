import sys

import boto3


def main():
    s3 = boto3.client('s3')
    args = len(sys.argv)
    if args < 2:
        print("Please specify S3 Bucket")
        exit(255)
    bucket = sys.argv[1]
    paginator = s3.get_paginator('list_object_versions')
    page_iterator = paginator.paginate(Bucket=bucket)
    for page in page_iterator:
        if 'Versions' in page:
            for version in page['Versions']:
                version_id = version['VersionId']
                key = version['Key']
                s3.delete_object(
                    Key=key,
                    VersionId=version_id,
                    Bucket=bucket
                )
    print("Bucket cleaned")


if __name__ == '__main__':
    main()
