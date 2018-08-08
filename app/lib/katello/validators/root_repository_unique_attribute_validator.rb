module Katello
  module Validators
    class RootRepositoryUniqueAttributeValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        exists = RootRepository.where(attribute => value).where("id != ?", record.id || -1).exists?

        if record.send("#{attribute}_changed?") && record.custom? && exists
          record.errors[attribute] << _("has already been taken for this product.")
        end
      end
    end
  end
end
