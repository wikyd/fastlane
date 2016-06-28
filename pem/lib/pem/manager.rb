require 'pathname'
require 'spaceship'


module Spaceship
  class PortalClient < Spaceship::Client

    def create_certificate!(type, csr, app_id = nil)
      ensure_csrf

      puts "MONKEYS MONKEYS MONKEYS"
      r = request(:post, 'account/mac/certificate/submitCertificateRequest.action', {
        teamId: team_id,
        type: type,
        csrContent: csr,
        appIdId: app_id # optional
      })
      parse_response(r, 'certRequest')
    end

  end

  module Portal

    class Certificate
      class << self

        def create!(csr: nil, bundle_id: nil)
          type = CERTIFICATE_TYPE_IDS.key(self)

          # look up the app_id by the bundle_id
          if bundle_id
            app = Spaceship::App.find(bundle_id, mac: true)
            raise "Could not find app with bundle id '#{bundle_id}'" unless app
            app_id = app.app_id
          end

          # ensure csr is a OpenSSL::X509::Request
          csr = OpenSSL::X509::Request.new(csr) if csr.kind_of?(String)

          # if this succeeds, we need to save the .cer and the private key in keychain access or wherever they go in linux
          puts "BEFORE CREATE"
          response = client.create_certificate!(type, csr.to_pem, app_id)
          puts "AFTER CREATE"
          # munge the response to make it work for the factory
          response['certificateTypeDisplayId'] = response['certificateType']['certificateTypeDisplayId']
          self.new(response)
        end

      end
    end
  end
end

module PEM
  # Creates the push profile and stores it in the correct location
  class Manager
    class << self
      def start
        FastlaneCore::PrintTable.print_values(config: PEM.config, hide_keys: [:new_profile], title: "Summary for PEM #{PEM::VERSION}")
        login

        existing_certificate = certificate.all.detect do |c|
          c.name == PEM.config[:app_identifier]
        end

        if existing_certificate
          remaining_days = (existing_certificate.expires - Time.now) / 60 / 60 / 24
          UI.message "Existing push notification profile '#{existing_certificate.owner_name}' is valid for #{remaining_days.round} more days."
          if remaining_days > 30
            if PEM.config[:force]
              UI.success "You already have an existing push certificate, but a new one will be created since the --force option has been set."
            else
              UI.success "You already have a push certificate, which is active for more than 30 more days. No need to create a new one"
              UI.success "If you still want to create a new one, use the --force option when running PEM."
              return false
            end
          end
        end

        return create_certificate
      end

      def login
        UI.message "Starting login with user '#{PEM.config[:username]}'"
        Spaceship.login(PEM.config[:username], nil)
        Spaceship.client.select_team
        UI.message "Successfully logged in"
      end

      # rubocop:disable Metrics/AbcSize
      def create_certificate
        UI.important "Creating a new push certificate for app '#{PEM.config[:app_identifier]}'."

        csr, pkey = Spaceship.certificate.create_certificate_signing_request

        begin
          cert = certificate.create!(csr: csr, bundle_id: PEM.config[:app_identifier])
        rescue => ex
          if ex.to_s.include? "You already have a current"
            # That's the most common failure probably
            UI.message ex.to_s
            UI.user_error!("You already have 2 active push profiles for this application/environment. You'll need to revoke an old certificate to make room for a new one")
          else
            raise ex
          end
        end

        x509_certificate = cert.download
        certificate_type = (PEM.config[:development] ? 'development' : 'production')
        filename_base = PEM.config[:pem_name] || "#{certificate_type}_#{PEM.config[:app_identifier]}"
        filename_base = File.basename(filename_base, ".pem") # strip off the .pem if it was provided.

        if PEM.config[:save_private_key]
          private_key_path = File.join(PEM.config[:output_path], "#{filename_base}.pkey")
          File.write(private_key_path, pkey.to_pem)
          UI.message("Private key: ".green + Pathname.new(private_key_path).realpath.to_s)
        end

        if PEM.config[:generate_p12]
          output_path = PEM.config[:output_path]
          FileUtils.mkdir_p(File.expand_path(output_path))
          p12_cert_path = File.join(output_path, "#{filename_base}.p12")
          p12 = OpenSSL::PKCS12.create(PEM.config[:p12_password], certificate_type, pkey, x509_certificate)
          File.write(p12_cert_path, p12.to_der)
          UI.message("p12 certificate: ".green + Pathname.new(p12_cert_path).realpath.to_s)
        end

        x509_cert_path = File.join(PEM.config[:output_path], "#{filename_base}.pem")
        File.write(x509_cert_path, x509_certificate.to_pem + pkey.to_pem)
        UI.message("PEM: ".green + Pathname.new(x509_cert_path).realpath.to_s)
        return x509_cert_path
      end
      # rubocop:enable Metrics/AbcSize

      def certificate
        if PEM.config[:development]
          Spaceship.certificate.mac_development_push
        else
          Spaceship.certificate.mac_production_push
        end
      end
    end
  end
end
