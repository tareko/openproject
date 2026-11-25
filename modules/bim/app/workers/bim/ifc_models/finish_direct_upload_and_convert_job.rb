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
    # The conversion reads the IFC file from its final storage, which only holds the file once
    # the direct upload is finished. So the upload is finished first, and the conversion scheduled after.
    class FinishDirectUploadAndConvertJob < ::ApplicationJob
      queue_with_priority :high

      def perform(ifc_model)
        attachment = ifc_model.ifc_attachment

        ::Attachments::FinishDirectUploadJob.perform_now(attachment.id, allowlist: false)

        ScheduleConversionService.new(ifc_model).upload_finished if upload_finished?(attachment)
      end

      private

      def upload_finished?(attachment)
        Attachment.not_pending_direct_upload.exists?(attachment.id)
      end
    end
  end
end
