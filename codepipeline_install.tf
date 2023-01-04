


////////////////////////////////////////////////////////[ CODEPIPELINE ]//////////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Create CodeStarSourceConnection
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_codestarconnections_connection" "github" {
  for_each      = var.app["install"] == "enabled" ? toset(["enabled"]) : []
  name          = "${local.project}-codestar-connection"
  provider_type = "GitHub"
  
  tags = {
     Name       = "${local.project}-codestar-connection"
  }
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Create CodeBuild project
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_codebuild_project" "install" {
  for_each               = var.app["install"] == "enabled" ? toset(["enabled"]) : []
  badge_enabled          = false
  build_timeout          = 60
  description            = "${local.project}-codebuild-install-project"
  name                   = "${local.project}-codebuild-install-project"
  queued_timeout         = 480
  depends_on             = [aws_iam_role.codebuild]
  service_role           = aws_iam_role.codebuild.arn

  tags = {
    Name = "${local.project}-codebuild-install-project"
  }

  artifacts {
    encryption_disabled    = false
    name                   = "${local.project}-codebuild-install-project"
    override_artifact_name = false
    packaging              = "NONE"
    type                   = "CODEPIPELINE"
  }

  cache {
    modes = []
    type  = "NO_CACHE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "aws/codebuild/standard:5.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false
    type                        = "LINUX_CONTAINER"
          
    environment_variable {
      name  = "PARAMETERSTORE"
      value = "${aws_ssm_parameter.env.name}"
      type  = "PARAMETER_STORE"
    }
    
    environment_variable {
      name  = "PHP_VERSION"
      value = "${var.app["php_version"]}"
      type  = "PLAINTEXT"
    }
  }

  vpc_config {
    vpc_id             = aws_vpc.this.id
    subnets            = values(aws_subnet.this).*.id
    security_group_ids = [
      aws_security_group.ec2.id
    ]
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = aws_cloudwatch_log_stream.codebuild.name
      status      = "ENABLED"
    }

    s3_logs {
      status = "DISABLED"
    }
  }

  source {
    buildspec           = "${file("${abspath(path.root)}/codepipeline/installspec.yml")}"
    git_clone_depth     = 0
    insecure_ssl        = false
    report_build_status = false
    type                = "CODEPIPELINE"
  }
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Create CodePipeline configuration
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_codepipeline" "install" {
  for_each   = var.app["install"] == "enabled" ? toset(["enabled"]) : []
  name       = "${local.project}-codepipeline-install"
  depends_on = [aws_iam_role.codepipeline]
  role_arn   = aws_iam_role.codepipeline.arn
  tags       = {
     Name    = "${local.project}-codepipeline-install"
  }

  artifact_store {
    location = aws_s3_bucket.this["system"].bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      category = "Source"
      configuration = {
        "ConnectionArn"         = aws_codestarconnections_connection.github[each.key].arn
        "FullRepositoryId"      = var.app["source_repo"]
        "BranchName"            = "main"
        "OutputArtifactFormat"  = "CODEBUILD_CLONE_REF"
        "PollForSourceChanges"  = "false"
      }
      input_artifacts = []
      name            = "Source"
      namespace       = "SourceVariables"
      output_artifacts = [
        "SourceArtifact",
      ]
      owner     = "AWS"
      provider  = "CodeStarSourceConnection"
      version   = "1"
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Approval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      run_order = 1
      configuration = {
        NotificationArn = aws_sns_topic.default.arn
        CustomData      = "Run CodePipeline to install your app?"
      }
    }

    action {
      category = "Build"
      configuration = {
        "ProjectName" = aws_codebuild_project.install[each.key].id
      }
      input_artifacts = [
        "SourceArtifact",
      ]
      name      = "Build"
      namespace = "BuildVariables"
      output_artifacts = [
        "BuildArtifact",
      ]
      owner     = "AWS"
      provider  = "CodeBuild"
      region    = data.aws_region.current.name
      run_order = 2
      version   = "1"
    }
  }

  stage {
    name = "Deploy"

    action {
      category = "Deploy"
      configuration = {
                BucketName = aws_s3_bucket.this["backup"].bucket
                Extract    = false
                ObjectKey  = "deploy/${local.project}-install.zip"
                }
      input_artifacts = [
        "BuildArtifact",
      ]
      name             = "Deploy"
      namespace        = "DeployVariables"
      output_artifacts = []
      owner            = "AWS"
      provider         = "S3"
      region           = data.aws_region.current.name
      run_order        = 1
      version          = "1"
    }
  }
}
