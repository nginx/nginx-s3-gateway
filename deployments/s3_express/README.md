# Purpose

This Terraform script sets up an AWS S3 Express One Zone bucket for testing.

## Usage

Use environment variables to authenticate:

```bash
export AWS_ACCESS_KEY_ID="anaccesskey"
export AWS_SECRET_ACCESS_KEY="asecretkey"
export AWS_REGION="us-west-2"
```

Generate a plan:

```bash
terraform plan -out=plan.tfplan \
>   -var="bucket_name=my-bucket-name--usw2-az1--x-s3" \
>   -var="region=us-west-2" \
>   -var="availability_zone_id=usw2-az1" \
>   -var="owner_email=my_email@foo.com"
```

> [!NOTE]
> Note that AWS S3 Express One Zone is only available in
> [certain regions and availability zones][s3-express-endpoints]. If you get an error like this:
> `api error InvalidBucketName`. If you have met the [naming rules][bucket-naming-rules], this likely means you have
> chosen a bad region/availability zone combination.

[s3-express-endpoints]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-networking.html#s3-express-endpoints
[bucket-naming-rules]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/directory-bucket-naming-rules.html

If you are comfortable with the plan, apply it:

```text
terraform apply "plan.tfplan"
```

Then build the image (you can also use the latest release)

```bash
docker build --file Dockerfile.oss --tag nginx-s3-gateway:oss --tag nginx-s3-gateway .
```

Configure and run the image:

```bash
docker run --rm --env-file ./settings.s3express.example --publish 80:80 --name nginx-s3-gateway \
    nginx-s3-gateway:oss
```

Confirm that it is working. The terraform script will prepopulate the bucket with a single test object

```bash
curl http://localhost:80/test.txt
```
