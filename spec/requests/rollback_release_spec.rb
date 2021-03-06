require "rails_helper"

describe "POST /heritages/:heritage/releases/:version/rollback", type: :request do
  let(:user) { create :user }
  let(:district) { create :district }

  before do
    params = {
      name: "nginx",
      image_name: "nginx",
      image_tag: "latest",
      before_deploy: "echo hello",
      services: [
        {
          name: "web",
          public: true,
          cpu: 128,
          memory: 256,
          command: "nginx",
          port_mappings: [
            {
              lb_port: 80,
              container_port: 80
            }
          ]
        }
      ]
    }
    api_request :post, "/v1/districts/#{district.name}/heritages", params
    api_request :patch, "/v1/heritages/nginx", {"image_tag" => "v111"}
  end

  it "rolls back to the specified version" do
    api_request :post, "/v1/heritages/nginx/releases/1/rollback"
    expect(response).to be_successful

    release = JSON.load(response.body)["release"]
    expect(release["version"]).to eq 3
    expect(release["description"]).to eq "Rolled back to version 1"
    expect(release["data"]).to include("image_name" => "nginx", "image_tag" => "latest")
  end
end
