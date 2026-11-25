require "spec_helper"
require "services/base_services/behaves_like_create_service"

RSpec.describe Bim::IfcModels::CreateService do
  it_behaves_like "BaseServices create service" do
    let(:model_class) { Bim::IfcModels::IfcModel }
    let(:factory) { :ifc_model }
    let!(:conversion_job) do
      double("ifc_conversion_job").tap do |job|
        allow(job).to receive(:perform_later)

        stub_const("Bim::IfcModels::IfcConversionJob", job)
      end
    end
    let(:ifc_attachment) { build_stubbed(:attachment, description: "ifc") }

    before do
      allow(model_instance).to receive(:ifc_attachment).and_return(ifc_attachment)
    end

    it "queues a conversion job" do
      expect(conversion_job)
        .to(receive(:perform_later))
        .with(model_instance)

      subject
    end

    context "with virus scanning enabled",
            with_ee: %i[virus_scanning],
            with_settings: { antivirus_scan_mode: :clamav_socket } do
      it "queues no conversion job, as the virus scan of the IFC file queues it" do
        subject

        expect(conversion_job).not_to have_received(:perform_later)
      end
    end

    context "if the IFC file is a direct upload that is not finished yet" do
      let(:ifc_attachment) { build_stubbed(:pending_direct_upload, description: "ifc") }

      it "queues no conversion job, as finishing the upload queues it" do
        subject

        expect(conversion_job).not_to have_received(:perform_later)
      end
    end

    context "if the SetAttributeService is unsuccessful" do
      let(:set_attributes_success) { false }

      it "queues no conversion job" do
        expect(conversion_job).not_to receive(:perform_later)

        subject
      end
    end

    context "when the model is invalid" do
      let(:model_save_result) { false }

      it "queues no conversion job" do
        expect(conversion_job).not_to receive(:perform_later)

        subject
      end
    end
  end
end
