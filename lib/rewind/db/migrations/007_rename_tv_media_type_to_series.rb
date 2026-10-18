# frozen_string_literal: true

Sequel.migration do
  up do
    from(:items).where(media_type: "tv").update(media_type: "series")
  end

  down do
    from(:items).where(media_type: "series").update(media_type: "tv")
  end
end
