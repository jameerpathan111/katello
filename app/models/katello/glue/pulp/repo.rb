module Katello
  module Glue::Pulp::Repo
    # TODO: move into submodules
    # rubocop:disable MethodLength
    # rubocop:disable ModuleLength
    def self.included(base)
      base.send :include, LazyAccessor
      base.send :include, InstanceMethods

      base.class_eval do
        lazy_accessor :pulp_repo_facts,
                      :initializer => (lambda do |_s|
                                         if pulp_id
                                           begin
                                             Katello.pulp_server.extensions.repository.retrieve_with_details(pulp_id)
                                           rescue RestClient::ResourceNotFound
                                             nil # not found = it was not orchestrated yet
                                           end
                                         end
                                       end)

        lazy_accessor :importers,
                      :initializer => lambda { |_s| pulp_repo_facts["importers"] if pulp_id }

        lazy_accessor :distributors,
                      :initializer => lambda { |_s| pulp_repo_facts["distributors"] if pulp_id }

        def self.delete_orphaned_content
          Katello.pulp_server.resources.content.remove_orphans
        end

        def self.distribution_bootable?(distribution)
          # Not every distribution from Pulp represents a bootable
          # repo. Determine based on the files in the repo.
          distribution["files"].any? do |file|
            if file.is_a? Hash
              filename = file[:relativepath]
            else
              filename = file
            end
            filename.include?('vmlinuz') || filename.include?('pxeboot') || filename.include?('kernel.img') || filename.include?('initrd.img')
          end
        end

        def self.needs_importer_updates(repos, capsule_content)
          repos.select do |repo|
            repo_details = capsule_content.pulp_repo_facts(repo.pulp_id)
            next unless repo_details
            capsule_importer = repo_details["importers"][0]
            !repo.importer_matches?(capsule_importer, capsule_content.capsule)
          end
        end

        def self.needs_distributor_updates(repos, capsule_content)
          repos.select do |repo|
            repo_details = capsule_content.pulp_repo_facts(repo.pulp_id)
            next unless repo_details
            !repo.distributors_match?(repo_details["distributors"], capsule_content.capsule)
          end
        end
      end
    end

    module InstanceMethods
      # TODO: This module is too long. See https://projects.theforeman.org/issues/12584.
      def last_sync
        last = self.latest_dynflow_sync
        last.nil? ? nil : last.to_s
      end

      def initialize(attrs = nil)
        if attrs.nil?
          super
        else
          #rename "type" to "cp_type" (activerecord and candlepin variable name conflict)
          #if attrs.has_key?(type_key) && !(attrs.has_key?(:cp_type) || attrs.has_key?('cp_type'))
          #  attrs[:cp_type] = attrs[type_key]
          #end

          attrs_used_by_model = attrs.reject do |k, _v|
            !self.class.column_defaults.keys.member?(k.to_s) && (!respond_to?(:"#{k.to_s}=") rescue true)
          end
          super(attrs_used_by_model)
        end
      end

      def srpm_count
        pulp_repo_facts['content_unit_counts']['srpm']
      end

      def uri
        uri = URI.parse(SETTINGS[:katello][:pulp][:url])
        "https://#{uri.host}/pulp/repos/#{relative_path}"
      end

      def to_hash
        pulp_repo_facts.merge(as_json).merge(:sync_state => sync_state)
      end

      def pulp_scratchpad_checksum_type
        pulp_repo_facts&.dig('scratchpad', 'checksum_type')
      end

      def pulp_counts_differ?
        pulp_counts = pulp_repo_facts[:content_unit_counts]
        rpms.count != pulp_counts['rpm'].to_i ||
          errata.count != pulp_counts['erratum'].to_i ||
          package_groups.count != pulp_counts['package_group'].to_i ||
          puppet_modules.count != pulp_counts['puppet_module'].to_i ||
          docker_manifests.count != pulp_counts['docker_manifest'].to_i ||
          docker_tags.count != pulp_counts['docker_tag'].to_i ||
          ostree_branches.count != pulp_counts['ostree'].to_i
      end

      def empty_in_pulp?
        pulp_repo_facts[:content_unit_counts].values.all? { |value| value == 0 }
      end

      def create_pulp_repo
        #if we are in library, no need for an distributor, but need to sync
        if self.environment.try(:library?)
          importer = generate_importer
        else
          #if not in library, no need for sync info, but we need a distributor
          case self.content_type
          when Repository::YUM_TYPE
            importer = Runcible::Models::YumImporter.new
          when Repository::PUPPET_TYPE
            importer = Runcible::Models::PuppetImporter.new
          when Repository::DEB_TYPE
            importer = Runcible::Models::DebImporter.new
          end
        end

        distributors = generate_distributors

        Katello.pulp_server.extensions.repository.create_with_importer_and_distributors(self.pulp_id,
                                                                                        importer,
                                                                                        distributors,
                                                                                        :display_name => self.name)
      rescue RestClient::ServiceUnavailable => e
        message = _("Pulp service unavailable during creating repository '%s', please try again later.") % self.name
        raise PulpErrors::ServiceUnavailable.new(message, e)
      end

      def generate_importer(capsule = SmartProxy.default_capsule!)
        case self.content_type
        when Repository::YUM_TYPE
          Runcible::Models::YumImporter.new(yum_importer_values(capsule))
        when Repository::FILE_TYPE
          Runcible::Models::IsoImporter.new(importer_connection_options(capsule).merge(:feed => importer_feed_url(capsule)))
        when Repository::PUPPET_TYPE
          Runcible::Models::PuppetImporter.new(puppet_importer_values(capsule))
        when Repository::DOCKER_TYPE
          options = {}
          options[:upstream_name] = capsule.default_capsule? ? self.docker_upstream_name : self.container_repository_name
          options[:feed] = docker_feed_url(capsule)
          options[:enable_v1] = false
          options[:tags] = capsule.default_capsule? ? self.docker_tags_whitelist : nil
          Runcible::Models::DockerImporter.new(importer_connection_options(capsule).merge(options))
        when Repository::OSTREE_TYPE
          options = importer_connection_options(capsule)
          options[:depth] = capsule.default_capsule? ? compute_ostree_upstream_sync_depth : ostree_capsule_sync_depth
          options[:feed] = self.importer_feed_url(capsule)
          Runcible::Models::OstreeImporter.new(options)
        when Repository::DEB_TYPE
          Runcible::Models::DebImporter.new(deb_importer_values(capsule))
        else
          fail _("Unexpected repo type %s") % self.content_type
        end
      end

      def docker_feed_url(capsule = SmartProxy.default_capsule!)
        pulp_uri = URI.parse(SETTINGS[:katello][:pulp][:url])
        if capsule.default_capsule?
          self.url if self.respond_to?(:url)
        else
          "https://#{pulp_uri.host.downcase}:#{Setting['pulp_docker_registry_port']}"
        end
      end

      def importer_feed_url(capsule = SmartProxy.default_capsule!)
        if capsule.default_capsule?
          self.url if self.respond_to?(:url)
        else
          self.full_path(nil, true)
        end
      end

      def yum_importer_values(capsule)
        if capsule.default_capsule?
          new_download_policy = self.download_policy
        else
          new_download_policy = capsule_download_policy(capsule)
        end

        config = {
          :feed => self.importer_feed_url(capsule),
          :download_policy => new_download_policy,
          :remove_missing => capsule.default_capsule? ? self.mirror_on_sync? : true
        }
        config[:type_skip_list] = ignorable_content if ignorable_content
        config.merge(importer_connection_options(capsule))
      end

      def proxy_host_value
        self.ignore_global_proxy ? "" : nil
      end

      def puppet_importer_values(capsule)
        config = {
          :feed => self.importer_feed_url(capsule),
          :remove_missing => capsule.default_capsule? ? self.mirror_on_sync? : true
        }
        config.merge(importer_connection_options(capsule))
      end

      def deb_importer_values(capsule)
        config = {
          feed: self.importer_feed_url(capsule),
          releases: self.deb_releases,
          components: self.deb_components,
          architectures: self.deb_architectures
        }
        config.merge(importer_connection_options(capsule))
      end

      def importer_connection_options(capsule = SmartProxy.default_capsule!)
        if !capsule.default_capsule?
          ueber_cert = ::Cert::Certs.ueber_cert(organization)
          importer_options = {
            :ssl_client_cert => ueber_cert[:cert],
            :ssl_client_key => ueber_cert[:key],
            :ssl_ca_cert => ::Cert::Certs.ca_cert
          }
        elsif self.try(:redhat?) && self.content_view.default? && Katello::Resources::CDN::CdnResource.redhat_cdn?(url)
          importer_options = {
            :ssl_client_cert => self.product.certificate,
            :ssl_client_key => self.product.key,
            :ssl_ca_cert => Katello::Repository.feed_ca_cert(url),
            :proxy_host => self.proxy_host_value
          }
        elsif self.ssl_client_cert && self.ssl_client_key && self.ssl_ca_cert
          importer_options = {
            :ssl_client_cert => self.ssl_client_cert.content,
            :ssl_client_key => self.ssl_client_key.content,
            :ssl_ca_cert => self.ssl_ca_cert.content
          }
        else
          importer_options = {
            :ssl_client_cert => nil,
            :ssl_client_key => nil,
            :ssl_ca_cert => nil,
            :proxy_host => self.proxy_host_value
          }
        end
        unless self.is_a?(::Katello::ContentViewPuppetEnvironment)
          importer_options.merge!(:ssl_validation => verify_ssl_on_sync?)
          if capsule.default_capsule?
            importer_options.merge!(:basic_auth_username => upstream_username,
                                    :basic_auth_password => upstream_password)
          end
        end
        importer_options
      end

      def generate_distributors(capsule = SmartProxy.default_capsule!)
        case self.content_type
        when Repository::YUM_TYPE
          yum_dist_id = self.pulp_id
          yum_dist_options = {:protected => true, :id => yum_dist_id, :auto_publish => true}
          yum_dist_options[:skip] = ignorable_content if ignorable_content
          #check the instance variable, as we do not want to go to pulp
          yum_dist_options['checksum_type'] = self.saved_checksum_type || self.checksum_type
          yum_dist = Runcible::Models::YumDistributor.new(self.relative_path, self.unprotected, true,
                                                          yum_dist_options)
          clone_dist = Runcible::Models::YumCloneDistributor.new(:id => "#{self.pulp_id}_clone",
                                                                 :destination_distributor_id => yum_dist_id)
          export_dist = Runcible::Models::ExportDistributor.new(false, false, self.relative_path)
          distributors = [yum_dist, export_dist]
          distributors << clone_dist if capsule.default_capsule?
        when Repository::FILE_TYPE
          dist = Runcible::Models::IsoDistributor.new(self.relative_path, self.unprotected, true, auto_publish: true)
          distributors = [dist]
        when Repository::PUPPET_TYPE
          capsule ||= SmartProxy.default_capsule!
          dist_options = { :id => self.pulp_id, :auto_publish => true }
          repo_path =  File.join(capsule.puppet_path,
                                 Environment.construct_name(self.organization,
                                                            self.environment,
                                                            self.content_view),
                                 'modules')
          puppet_install_dist = Runcible::Models::PuppetInstallDistributor.new(repo_path, dist_options)

          dist_options[:id] = "#{self.pulp_id}_puppet"
          puppet_dist = Runcible::Models::PuppetDistributor.new(nil, (self.unprotected || false),
                                                                true, dist_options)

          distributors = [puppet_dist, puppet_install_dist]
        when Repository::DOCKER_TYPE
          options = { :protected => !self.unprotected, :id => self.pulp_id, :auto_publish => true,
                      :repo_registry_id => container_repository_name}
          docker_dist = Runcible::Models::DockerDistributor.new(options)
          distributors = [docker_dist]
        when Repository::OSTREE_TYPE
          options = { :id => self.pulp_id,
                      :auto_publish => true,
                      :relative_path => relative_path,
                      :depth => self.root.compute_ostree_upstream_sync_depth }

          dist = Runcible::Models::OstreeDistributor.new(options)
          distributors = [dist]
        when Repository::DEB_TYPE
          options = {
            id: self.pulp_id,
            auto_publish: true
          }
          http = self.unprotected
          https = true
          dist = Runcible::Models::DebDistributor.new(self.relative_path, http, https, options)
          distributors = [dist]
        else
          fail _("Unexpected repo type %s") % self.content_type
        end

        distributors
      end

      def importer_type
        case self.content_type
        when Repository::YUM_TYPE
          Runcible::Models::YumImporter::ID
        when Repository::FILE_TYPE
          Runcible::Models::IsoImporter::ID
        when Repository::PUPPET_TYPE
          Runcible::Models::PuppetImporter::ID
        when Repository::DOCKER_TYPE
          Runcible::Models::DockerImporter::ID
        when Repository::OSTREE_TYPE
          Runcible::Models::OstreeImporter::ID
        when Repository::DEB_TYPE
          Runcible::Models::DebImporter::ID
        else
          fail _("Unexpected repo type %s") % self.content_type
        end
      end

      def populate_from(repos_map)
        found = repos_map[self.pulp_id]
        prepopulate(found) if found
        !found.nil?
      end

      def package_group_count
        content_unit_counts = 0
        if self.pulp_repo_facts
          content_unit_counts = self.pulp_repo_facts[:content_unit_counts][:package_group]
        end
        content_unit_counts
      end

      def sync(options = {})
        sync_options = {}
        sync_options[:max_speed] ||= SETTINGS[:katello][:pulp][:sync_KBlimit] if SETTINGS[:katello][:pulp][:sync_KBlimit] # set bandwidth limit
        sync_options[:num_threads] ||= SETTINGS[:katello][:pulp][:sync_threads] if SETTINGS[:katello][:pulp][:sync_threads] # set threads per sync
        pulp_tasks = Katello.pulp_server.extensions.repository.sync(self.pulp_id, :override_config => sync_options)

        task = PulpSyncStatus.using_pulp_task(pulp_tasks) do |t|
          t.organization = organization
          t.parameters ||= {}
          t.parameters[:options] = options
        end
        task.save!
        return [task]
      end

      def clone_file_metadata(to_repo)
        Katello.pulp_server.extensions.yum_repo_metadata_file.copy(self.pulp_id, to_repo.pulp_id)
      end

      def unassociate_by_filter(content_type, filter_clauses)
        criteria = {:type_ids => [content_type], :filters => {:unit => filter_clauses}}
        case content_type
        when Katello.pulp_server.extensions.rpm.content_type
          criteria[:fields] = { :unit => Pulp::Rpm::PULP_SELECT_FIELDS}
        when Katello.pulp_server.extensions.errata.content_type
          criteria[:fields] = { :unit => Pulp::Erratum::PULP_SELECT_FIELDS}
        end
        Katello.pulp_server.extensions.repository.unassociate_units(self.pulp_id, criteria)
      end

      def clear_contents
        tasks = content_types.flat_map { |type| type.unassociate_from_repo(self.pulp_id, {}) }

        tasks << Katello.pulp_server.extensions.repository.unassociate_units(self.pulp_id,
                   :type_ids => ['rpm'], :filters => {}, :fields => { :unit => Pulp::Rpm::PULP_SELECT_FIELDS})
        tasks
      end

      def content_types
        [Katello.pulp_server.extensions.errata,
         Katello.pulp_server.extensions.package_group,
         Katello.pulp_server.extensions.puppet_module,
         Katello.pulp_server.extensions.module_stream
        ]
      end

      def sync_status
        self._get_most_recent_sync_status if @sync_status.nil?
      end

      def sync_state
        status = sync_status
        return PulpSyncStatus::Status::NOT_SYNCED if status.nil?
        status.state
      end

      def synced?
        sync_history = self.sync_status
        !sync_history.nil? && successful_sync?(sync_history)
      end

      def successful_sync?(sync_history_item)
        sync_history_item['state'] == PulpTaskStatus::Status::FINISHED.to_s
      end

      def find_distributor(use_clone_distributor = false)
        dist_type_id = if use_clone_distributor
                         case self.content_type
                         when Repository::YUM_TYPE
                           Runcible::Models::YumCloneDistributor.type_id
                         when Repository::PUPPET_TYPE
                           Runcible::Models::PuppetInstallDistributor.type_id
                         end
                       else
                         case self.content_type
                         when Repository::YUM_TYPE
                           Runcible::Models::YumDistributor.type_id
                         when Repository::PUPPET_TYPE
                           Runcible::Models::PuppetInstallDistributor.type_id
                         end
                       end

        distributors.detect { |dist| dist["distributor_type_id"] == dist_type_id }
      end

      def sort_sync_status(statuses)
        statuses.sort! do |a, b|
          if a['finish_time'].nil? && b['finish_time'].nil?
            if a['start_time'].nil?
              1
            elsif b['start_time'].nil?
              -1
            else
              a['start_time'] <=> b['start_time']
            end
          elsif a['finish_time'].nil?
            if a['start_time'].nil?
              1
            else
              -1
            end
          elsif b['finish_time'].nil?
            if b['start_time'].nil?
              -1
            else
              1
            end
          else
            b['finish_time'] <=> a['finish_time']
          end
        end
        return statuses
      end

      def unit_type_id
        case content_type
        when Repository::YUM_TYPE
          "rpm"
        when Repository::PUPPET_TYPE
          "puppet_module"
        when Repository::DOCKER_TYPE
          "docker_manifest"
        when Repository::OSTREE_TYPE
          "ostree"
        when Repository::FILE_TYPE
          "iso"
        when Repository::DEB_TYPE
          "deb"
        end
      end

      def unit_search(options = {})
        Katello.pulp_server.extensions.repository.unit_search(self.pulp_id, options)
      end

      def docker?
        self.content_type == Repository::DOCKER_TYPE
      end

      def puppet?
        self.content_type == Repository::PUPPET_TYPE
      end

      def file?
        self.content_type == Repository::FILE_TYPE
      end

      def yum?
        self.content_type == Repository::YUM_TYPE
      end

      def ostree?
        self.content_type == Repository::OSTREE_TYPE
      end

      def deb?
        self.content_type == Repository::DEB_TYPE
      end

      def published?
        distributors.map { |dist| dist['last_publish'] }.compact.any?
      end

      def capsule_download_policy(capsule)
        policy = capsule.download_policy || Setting[:default_proxy_download_policy]
        if self.yum?
          if policy == ::SmartProxy::DOWNLOAD_INHERIT
            self.root.download_policy
          else
            policy
          end
        end
      end

      def distributors_match?(capsule_distributors, capsule)
        generated_distributor_configs = self.generate_distributors(capsule)
        generated_distributor_configs.all? do |gen_dist|
          type = gen_dist.class.type_id
          found_on_capsule = capsule_distributors.find { |dist| dist['distributor_type_id'] == type }
          found_on_capsule && filtered_distribution_config_equal?(gen_dist.config, found_on_capsule['config'])
        end
      end

      def needs_metadata_publish?
        last_publish = last_publish_task.try(:[], 'finish_time')
        last_sync = last_sync_task.try(:[], 'finish_time')
        return false if last_sync.nil?
        return true if last_publish.nil?

        Time.parse(last_sync) >= Time.parse(last_publish)
      end

      def last_sync_task
        tasks = Katello.pulp_server.extensions.repository.sync_status(self.pulp_id)
        most_recent_task(tasks)
      end

      def last_publish_task
        tasks = Katello.pulp_server.extensions.repository.publish_status(self.pulp_id)
        most_recent_task(tasks, true)
      end

      def most_recent_task(tasks, only_successful = false)
        tasks = tasks.select { |t| t['finish_time'] }.sort_by { |t| t['finish_time'] }
        tasks = tasks.select { |task| task['error'].nil? } if only_successful
        tasks.last
      end

      def filtered_distribution_config_equal?(generated_config, actual_config)
        generated = generated_config.clone
        actual = actual_config.clone
        #We store 'default' checksum type as nil, but pulp will default to sha256, so if we haven't set it, ignore it
        if generated.keys.include?('checksum_type') && generated['checksum_type'].nil?
          generated.delete('checksum_type')
          actual.delete('checksum_type')
        end
        generated.delete('repo-registry-id')
        generated == actual
      end

      def importer_matches?(capsule_importer, capsule)
        generated_importer = self.generate_importer(capsule)
        capsule_importer.try(:[], 'importer_type_id') == generated_importer.id &&
          generated_importer.config == capsule_importer['config']
      end

      protected

      def object_to_hash(object)
        hash = {}
        object.instance_variables.each { |var| hash[var.to_s.delete("@")] = object.instance_variable_get(var) }
        hash
      end

      def _get_most_recent_sync_status
        begin
          history = Katello.pulp_server.extensions.repository.sync_status(pulp_id)

          if history.blank?
            history = PulpSyncStatus.convert_history(Katello.pulp_server.extensions.repository.sync_history(pulp_id))
          end
        rescue
          history = PulpSyncStatus.convert_history(Katello.pulp_server.extensions.repository.sync_history(pulp_id))
        end

        if history.blank?
          return PulpSyncStatus.new(:state => PulpSyncStatus::Status::NOT_SYNCED)
        else
          history = sort_sync_status(history)
          return PulpSyncStatus.pulp_task(history.first.with_indifferent_access)
        end
      end
    end

    def full_path(smart_proxy = nil, force_https = false)
      pulp_uri = URI.parse(smart_proxy ? smart_proxy.url : SETTINGS[:katello][:pulp][:url])
      scheme   = (self.unprotected && !force_https) ? 'http' : 'https'
      if docker?
        "#{pulp_uri.host.downcase}:#{Setting['pulp_docker_registry_port']}/#{container_repository_name}"
      elsif file?
        "#{scheme}://#{pulp_uri.host.downcase}/pulp/isos/#{relative_path}/"
      elsif puppet?
        "#{scheme}://#{pulp_uri.host.downcase}/pulp/puppet/#{pulp_id}/"
      elsif ostree?
        "#{scheme}://#{pulp_uri.host.downcase}/pulp/ostree/web/#{relative_path}"
      elsif deb?
        "#{scheme}://#{pulp_uri.host.downcase}/pulp/deb/#{relative_path}/"
      else
        "#{scheme}://#{pulp_uri.host.downcase}/pulp/repos/#{relative_path}/"
      end
    end

    def index_yum_content(full_index = false)
      if self.master?
        Katello::Rpm.import_for_repository(self, full_index)
        Katello::Srpm.import_for_repository(self, full_index)
        Katello::Erratum.import_for_repository(self)
        Katello::PackageGroup.import_for_repository(self)
        Katello::ModuleStream.import_for_repository(self)
        self.import_distribution_data
      else
        index_linked_repo
      end
    end

    def index_linked_repo
      if (base_repo = self.target_repository)
        Rpm.copy_repository_associations(base_repo, self)
        Erratum.copy_repository_associations(base_repo, self)
        PackageGroup.copy_repository_associations(base_repo, self)
        ModuleStream.copy_repository_associations(base_repo, self)
        self.update_attributes!(
          :distribution_version => base_repo.distribution_version,
          :distribution_arch => base_repo.distribution_arch,
          :distribution_family => base_repo.distribution_family,
          :distribution_variant => base_repo.distribution_variant,
          :distribution_uuid => base_repo.distribution_uuid,
          :distribution_bootable => base_repo.distribution_bootable
        )
      else
        Rails.logger.error("Cannot index #{self.id}, no target repository found.")
      end
    end

    def index_content(full_index = false)
      if self.yum?
        index_yum_content(full_index)
      elsif self.docker?
        Katello::DockerManifest.import_for_repository(self)
        Katello::DockerManifestList.import_for_repository(self)
        Katello::DockerTag.import_for_repository(self)
      elsif self.puppet?
        Katello::PuppetModule.import_for_repository(self)
      elsif self.ostree?
        Katello::OstreeBranch.import_for_repository(self)
      elsif self.file?
        Katello::FileUnit.import_for_repository(self)
      elsif self.deb?
        Katello::Deb.import_for_repository(self)
      end
      true
    end
  end
end
