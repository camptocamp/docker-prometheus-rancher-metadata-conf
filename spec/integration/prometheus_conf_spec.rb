require 'rubygems/package'
require 'rspec/core/pending'
require 'docker'
require 'yaml'
require "pp"

SPECDIR  = File.join(File.expand_path(File.dirname(__FILE__) + '/..'))
BASEDIR  = File.join(File.expand_path(File.dirname(__FILE__) + '/../..'))
FIXTURES = File.join(SPECDIR, "fixtures")

describe "When testing cattle-confd-prometheus integration" do

  # fetch container logs and search for the given regex. iterate until found
  # or timeout reached.
  def grep(regex, container, limit=20)
    counter = 0
    while counter < limit do
      return true unless container.logs(stdout: true).match(regex).nil?
      sleep 0.5
      counter += 1
    end
    puts container.logs(stdout: true)
    return false
  end

  def rancher_metadata_container
    Docker::Container.create(
      'Image' => 'camptocamp/rancher-metadata:v0.5.1',
      'HostConfig' => { 'Binds' => ["#{FIXTURES}/rancher-metadata:/answers"] },
      'Cmd' => ['-answers', '/answers/answers-sample.yml'], # '-debug'],
      'Tty' => true, 'OpenStdin' => true)
  end

  def confd_container
    # NB: build image before creating container
    image = Docker::Image.build_from_dir(BASEDIR)
    raise unless image.is_a? Docker::Image
    Docker::Container.create(
      'Image' => image.id,
      'HostConfig' => { 'Links': ["#{@metadata.id}:rancher-metadata"] },
      'Volumes' => { '/etc/prometheus-confd/' => {} },
      'Tty' => true, 'OpenStdin' => true)
  end

  def prometheus_container
    Docker::Container.create(
      'Image' => 'prom/prometheus:0.19.2',
      'HostConfig' => { 'VolumesFrom': ["#{@confd.id}"] },
      'Cmd' => ['-log.level=debug', '-config.file=/etc/prometheus-confd/prometheus.yml'],
      'Tty' => true, 'OpenStdin' => true)
  end

  before(:all) do
    @metadata = rancher_metadata_container
    @confd = confd_container
    @prometheus = prometheus_container
  end


  describe "standalone rancher-metadata helper should" do
    before(:context) do
      @metadata.start
    end
    it "run in a container" do
      expect(@metadata.class).to be Docker::Container
      expect(@metadata.json['State']['Running']).to be true
    end
    it "log answers file loading success" do
      expect(grep(/Loaded answers/, @metadata)).to be true
    end
    it "log TCP port binding success" do
      expect(grep(/Listening on :80/, @metadata)).to be true
    end
  end


  describe "confd should" do
    before(:context) do
      @confd.start
    end
    it "run in a container" do
      expect(@confd.class).to be Docker::Container
      expect(@confd.json['State']['Running']).to be true
    end
    it "log successful startup" do
      expect(grep(/INFO Starting confd/, @confd)).to be true
      expect(grep(/INFO Using Rancher Metadata URL/, @confd)).to be true
    end
    it "log successful file re-generation" do
      expect(grep(/INFO Target config .+prometheus-targets.yml has been updated/, @confd)).to be true
    end
  end


  describe "prometheus should" do
    before(:context) do
      @prometheus.start
    end
    it "run in a container" do
      expect(@prometheus.class).to be Docker::Container
      expect(@prometheus.json['State']['Running']).to be true
    end
    it "see 2 config files exported by confd" do
      ls = @prometheus.exec(['ls', '/etc/prometheus-confd/'], stdout: true)[0]
      files = ls.join('').split(/\s+/)
      expect(files.include?("prometheus-targets.yml")).to be true
      expect(files.include?("prometheus.yml")).to be true
    end
    it "ensure prometheus.yml is well formed" do
      cat = @prometheus.exec(['cat', '/etc/prometheus-confd/prometheus.yml'], stdout: true)[0][0]
      expect(YAML.load(cat).class).to be Hash
    end
    it "ensure prometheus-targets.yml is well formed" do
      cat = @prometheus.exec(['cat', '/etc/prometheus-confd/prometheus-targets.yml'], stdout: true)[0][0]
      puts cat
      yaml = YAML.load(cat)
      expect(yaml.class).to be Array
      expect(yaml.size).to be 5
      labels = yaml.last['labels']
      expect(labels['job']).to eq 'rancher'
      expect(labels['rancher_environment']).to eq 'lab'
      expect(labels['io_rancher_host_docker_version']).to eq '1.11'
      expect(labels['io_rancher_host_linux_kernel_version']).to eq '3.16'
      expect(labels['rancher_host']).to eq 'lab-rancher'
      expect(labels['some_label']).to eq 'true'
    end
    it "log successful config files parsing" do
      expect(grep(/Loading configuration file .+prometheus.yml/, @prometheus)).to be true
    end
    it "log successful startup" do
      expect(grep(/Listening on :9090/, @prometheus)).to be true
      expect(grep(/Starting target manager/, @prometheus)).to be true
    end
  end

  after(:all) do
    @metadata.delete(:force => true)
    @confd.delete(:force => true)
    @prometheus.delete(:force => true)
  end
end

