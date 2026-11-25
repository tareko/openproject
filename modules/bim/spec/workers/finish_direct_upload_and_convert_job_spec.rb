# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe Bim::IfcModels::FinishDirectUploadAndConvertJob do
  subject(:perform) { described_class.perform_now(ifc_model) }

  let(:ifc_model) { create(:ifc_model_without_ifc_attachment) }
  let!(:attachment) do
    create(:pending_direct_upload, container: ifc_model, description: "ifc", author: ifc_model.uploader)
  end
  let(:steps) { [] }

  before do
    allow(Attachments::FinishDirectUploadJob).to receive(:perform_now) do |attachment_id, **|
      steps << :upload_finished
      finish_upload(Attachment.find(attachment_id))
    end
    allow(Bim::IfcModels::IfcConversionJob).to receive(:perform_later) { steps << :conversion_queued }
  end

  context "when the upload is finished successfully" do
    def finish_upload(attachment)
      attachment.update_columns(status: Attachment.statuses[:uploaded])
    end

    it "finishes the direct upload first, and only then queues the conversion" do
      perform

      expect(steps).to eq(%i[upload_finished conversion_queued])
      expect(Attachments::FinishDirectUploadJob).to have_received(:perform_now).with(attachment.id, allowlist: false)
      expect(Bim::IfcModels::IfcConversionJob).to have_received(:perform_later).with(ifc_model)
    end

    context "with virus scanning enabled",
            with_ee: %i[virus_scanning],
            with_settings: { antivirus_scan_mode: :clamav_socket } do
      it "finishes the direct upload, and leaves the conversion to the virus scan" do
        perform

        expect(steps).to eq(%i[upload_finished])
      end
    end
  end

  context "when finishing the upload fails" do
    def finish_upload(attachment)
      attachment.destroy!
    end

    it "queues no conversion, as there is no IFC file to convert" do
      perform

      expect(steps).to eq(%i[upload_finished])
    end
  end
end
