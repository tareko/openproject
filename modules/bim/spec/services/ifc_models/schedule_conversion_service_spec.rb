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

RSpec.describe Bim::IfcModels::ScheduleConversionService do
  subject(:service) { described_class.new(ifc_model) }

  shared_let(:project) { create(:project, enabled_module_names: %i[bim]) }

  current_user do
    create(:user, member_with_permissions: { project => %i[view_ifc_models manage_ifc_models] })
  end

  let!(:ifc_model) { create(:ifc_model, project:) }

  before do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  describe "#upload_finished" do
    it "queues the conversion" do
      service.upload_finished

      expect(Bim::IfcModels::IfcConversionJob).to have_been_enqueued.with(ifc_model)
    end

    context "with virus scanning enabled",
            with_ee: %i[virus_scanning],
            with_settings: { antivirus_scan_mode: :clamav_socket } do
      it "leaves the conversion to the virus scan" do
        service.upload_finished

        expect(Bim::IfcModels::IfcConversionJob).not_to have_been_enqueued
      end
    end
  end

  describe "#file_scanned" do
    it "queues the conversion" do
      service.file_scanned

      expect(Bim::IfcModels::IfcConversionJob).to have_been_enqueued.with(ifc_model)
    end

    %i[completed processing].each do |status|
      context "when the model is already #{status}, e.g. after scanning existing files again" do
        before { ifc_model.update!(conversion_status: status) }

        it "queues nothing" do
          service.file_scanned

          expect(Bim::IfcModels::IfcConversionJob).not_to have_been_enqueued
        end
      end
    end
  end

  describe "when the virus scan has checked the IFC file",
           with_ee: %i[virus_scanning],
           with_settings: { antivirus_scan_mode: :clamav_socket, antivirus_scan_action: :quarantine } do
    let(:client_double) { instance_double(ClamAV::Client) }
    let(:attachment) { ifc_model.ifc_attachment }

    before do
      allow(ClamAV::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:execute).and_return(scan_response)
    end

    context "and found it clean" do
      let(:scan_response) { ClamAV::SuccessResponse.new("stream") }

      it "queues the conversion" do
        Attachments::VirusScanJob.perform_now(attachment)

        expect(attachment.reload).to be_status_scanned
        expect(Bim::IfcModels::IfcConversionJob).to have_been_enqueued.with(ifc_model)
      end
    end

    context "and found a virus" do
      let(:scan_response) { ClamAV::VirusResponse.new("stream", "Eicar-Test-Signature") }

      it "quarantines the file and queues no conversion" do
        Attachments::VirusScanJob.perform_now(attachment)

        expect(attachment.reload).to be_status_quarantined
        expect(Bim::IfcModels::IfcConversionJob).not_to have_been_enqueued
      end
    end
  end
end
