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

module Bim
  module IfcModels
    # The conversion needs the uploaded IFC file and, with virus scanning enabled, needs it scanned
    # clean. Whichever of these steps finishes last queues the conversion:
    # * upload_finished: CreateService, UpdateService and FinishDirectUploadAndConvertJob
    # * file_scanned: the ATTACHMENT_SCANNED subscription in the BIM engine
    class ScheduleConversionService
      attr_reader :ifc_model

      def initialize(ifc_model)
        @ifc_model = ifc_model
      end

      def upload_finished
        return if Setting::VirusScanning.enabled?

        queue_conversion
      end

      def file_scanned
        queue_conversion
      end

      private

      def queue_conversion
        return if ifc_model.completed? || ifc_model.processing?

        IfcConversionJob.perform_later(ifc_model)
      end
    end
  end
end
