import sys
import boto3
import os


def main():
    args = len(sys.argv)
    if args < 2:
        print("Please specify CloudFormation stack")
        exit(255)
    region = os.environ['AWS_REGION']
    cf = boto3.client('cloudformation', region_name=region)
    stack_name = sys.argv[1]
    cf.delete_stack(StackName=stack_name)
    waiter = cf.get_waiter('stack_delete_complete')
    waiter.wait(StackName=stack_name,
                WaiterConfig={
                    'Delay': 10,
                    'MaxAttempts': 100
                })


if __name__ == '__main__':
    main()
