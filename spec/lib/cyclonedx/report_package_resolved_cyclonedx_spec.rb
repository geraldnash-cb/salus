require_relative '../../spec_helper'
require 'json'

describe Cyclonedx::ReportPackageResolved do
  describe "#run" do
    it 'should report all the deps in the Package.resolved' do
      repo = Salus::Repo.new('spec/fixtures/report_package_resolved/normal')
      scanner = Salus::Scanners::ReportPackageResolved.new(repository: repo, config: {})
      scanner.run

      maven_cyclonedx = Cyclonedx::ReportPackageResolved.new(scanner.report)
      expect(maven_cyclonedx.build_components_object).to match_array(
        [
          {
            "bom-ref": "pkg:swift/Cryptor",
              type: "library",
              group: "",
              name: "Cryptor",
              version: "2.0.1",
              purl: "pkg:swift/Cryptor",
              properties: [
                {
                  key: "source",
                      value: ""
                },
                {
                  key: "dependency_file",
                    value: "Package.resolved"
                }
              ]
          },
          {
            "bom-ref": "pkg:swift/CryptorECC",
              type: "library",
              group: "",
              name: "CryptorECC",
              version: "1.2.200",
              purl: "pkg:swift/CryptorECC",
              properties: [
                {
                  key: "source",
                    value: ""
                },
                {
                  key: "dependency_file",
                    value: "Package.resolved"
                }
              ]
          },
          {
            "bom-ref": "pkg:swift/CryptorRSA",
              type: "library",
              group: "",
              name: "CryptorRSA",
              version: "1.0.201",
              purl: "pkg:swift/CryptorRSA",
              properties: [
                {
                  key: "source",
                    value: ""
                },
                {
                  key: "dependency_file",
                    value: "Package.resolved"
                }
              ]
          }
        ]
      )
    end

    it 'should produce valid CycloneDX under normal conditions' do
      repo = Salus::Repo.new('spec/fixtures/report_package_resolved/normal')

      scanner = Salus::Scanners::ReportPackageResolved.new(repository: repo, config: {})
      scanner.run

      cyclonedx_report = Cyclonedx::Report.new([[scanner.report, false]],
                                               { "spec_version" => "1.3" })
      cyclonedx_report_hash = cyclonedx_report.to_cyclonedx

      expect { Cyclonedx::Report.validate_cyclonedx(cyclonedx_report_hash) }.not_to raise_error
    end
  end
end
