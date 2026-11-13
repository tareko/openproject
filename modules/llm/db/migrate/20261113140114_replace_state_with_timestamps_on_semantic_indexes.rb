# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
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

# The state column is replaced by derived status: "indexing" while the claimed
# batch (indexing_batch_id) is unfinished, "ready" once a batch completed
# successfully (last_indexing_started_at watermark), "not_indexed" otherwise.
# Failures are stored as data (error_kind, error_message,
# failed_work_package_count) instead of a state.
class ReplaceStateWithTimestampsOnSemanticIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_column :semantic_indexes, :state, :string, null: false, default: "not_indexed"

    add_column :semantic_indexes, :last_indexing_started_at, :datetime
  end
end
