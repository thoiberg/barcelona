class ContainerInstance
  class UserData
    attr_accessor :files, :boot_commands, :run_commands, :packages, :users

    def initialize
      @files = []
      @boot_commands = []
      @run_commands = []
      @users = []
      @packages = ["aws-cli", "jq"]
    end

    def build
      user_data = {
        "repo_update" => true,
        "repo_upgrade" => "all",
        "packages" => packages.uniq,
        "write_files" => files,
        "bootcmd" => boot_commands,
        "runcmd" => run_commands,
        "users" => users
      }.reject{ |_, v| v.blank? }
      raw_user_data = "#cloud-config\n" << YAML.dump(user_data)
      Base64.encode64(raw_user_data)
    end

    def add_file(path, owner, permissions, content)
      @files << {
        "path" => path,
        "owner" => owner,
        "permissions" => permissions,
        "content" => content
      }
    end

    def add_user(name, authorized_keys: [], groups: [])
      @users << {
        "name" => name,
        "ssh-authorized-keys" => authorized_keys,
        "groups" => groups.join(',')
      }
    end
  end

  attr_accessor :district, :options
  delegate :aws, to: :district

  def initialize(district, options)
    @district = district
    @options = options
  end

  def launch
    resp = aws.ec2.run_instances(
      image_id: 'ami-e9724c87', # amzn-ami-2015.09.e-amazon-ecs-optimized
      min_count: 1,
      max_count: 1,
      user_data: instance_user_data,
      instance_type: options[:instance_type],
      instance_initiated_shutdown_behavior: "terminate",
      block_device_mappings: [
        {
          virtual_name: 'Root',
          device_name: '/dev/xvda',
          ebs: {
            volume_size: 80,
            delete_on_termination: true,
            volume_type: "gp2"
          }
        }
      ],
      network_interfaces: [
        {
          groups: [district.instance_security_group].compact,
          subnet_id: district.subnets.sample.subnet_id,
          device_index: 0,
          associate_public_ip_address: false
        }
      ],
      iam_instance_profile: {
        name: district.ecs_instance_profile
      }
    )
    instance_id = resp.instances[0].instance_id
    aws.ec2.create_tags(
      resources: [instance_id],
      tags: [
        {key: "Name", value: "barcelona-container-instance"},
        {key: "District", value: district.name}
      ]
    )
  end

  def instance_user_data
    user_data = UserData.new
    user_data.boot_commands += [
      "echo exclude=ecs-init >> /etc/yum.conf"
    ]
    user_data.run_commands += [
      "aws s3 cp s3://#{district.s3_bucket_name}/#{district.name}/ecs.config /etc/ecs/ecs.config",
      "sed -i 's/^#\\s%wheel\\s*ALL=(ALL)\\s*NOPASSWD:\\sALL$/%wheel\\tALL=(ALL)\\tNOPASSWD:\\tALL/g' /etc/sudoers",
      "chkconfig --add barcelona",
      "chkconfig barcelona on",
      "service barcelona start"
    ]

    user_data.add_file("/etc/init.d/barcelona", "root:root", "755", <<EOS)
#!/bin/bash
# chkconfig: 2345 96 04
# description: Barcelona

set -e

notify() {
  curl -X POST https://hooks.slack.com/services/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 -d "{\\"text\\": \\"$1\\"}"
}

stop() {
  AWS_REGION=ap-northeast-1
  ec2_instance_id=`curl http://169.254.169.254/latest/meta-data/instance-id`
  ecs_cluster=`curl http://localhost:51678/v1/metadata | jq -r .Cluster`
  container_instance_arn=`curl http://localhost:51678/v1/metadata | jq -r .ContainerInstanceArn | cut -d / -f2`

  notify "EC2 instance ID: $ec2_instance_id"
  notify "ECS cluster: $ecs_cluster"
  notify "ECS Container Instance ARN: $container_instance_arn"

  aws ecs deregister-container-instance --region $AWS_REGION --cluster $ecs_cluster --container-instance $container_instance_arn --force
  notify "Deregistered from $ecs_cluster"

  elb_names=`aws elb describe-load-balancers --region $AWS_REGION | jq -r ".LoadBalancerDescriptions | map(select(contains({Instances: [{InstanceId: \\"$ec2_instance_id\\"}]}))) | map(.LoadBalancerName) | join(\\" \\")"`

  for elb in $elb_names
  do
      notify "Deregistering the instance from $elb"
      aws elb deregister-instances-from-load-balancer --region $AWS_REGION --load-balancer-name $elb --instances $ec2_instance_id
  done

  while [[ -n "$elb_names" ]]
  do
      echo $elb_names
      notify "Waiting for the instance to be deregistered"
      elb_names=`aws elb describe-load-balancers --region $AWS_REGION | jq -r ".LoadBalancerDescriptions | map(select(contains({Instances: [{InstanceId: \\"$ec2_instance_id\\"}]}))) | map(.LoadBalancerName) | join(\\" \\")"`
      sleep 3
  done

  notify "Stopping docker containers..."
  container_ids=`docker stop -t 90 $(docker ps -q)`
  notify "Stopped $container_ids"
}

case "$1" in
  start)
    touch /var/lock/subsys/barcelona
    ;;
  stop)
    stop
    rm /var/lock/subsys/barcelona
    ;;
  *) exit 2;;
esac
EOS

    district.users.each do |user|
      user_data.add_user(user.name, authorized_keys: [user.public_key], groups: user.instance_groups)
      if district.dockercfg.present?
        name = user.name
        dockercfg = {"auths" => district.dockercfg}.to_json
        dockercfg_path = "/home/#{name}/.docker"
        user_data.run_commands += [
          "mkdir #{dockercfg_path}",
          "echo '#{dockercfg}' > #{dockercfg_path}/config.json",
          "chmod 600 #{dockercfg_path}/config.json",
          "chown #{name}:#{name} #{dockercfg_path}/config.json"
        ]
      end
    end

    user_data = district.hook_plugins(:container_instance_user_data, self, user_data)

    user_data.build
  end
end
