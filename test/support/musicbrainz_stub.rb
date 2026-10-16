# frozen_string_literal: true

module MusicBrainzStub
  def stub_fanart_artist(mbid, url: "https://fanart.example/artist.jpg")
    body = {"artistthumb" => [{"url" => url}]}
    WebMock.stub_request(:get, %r{webservice\.fanart\.tv/v3\.2/music/#{mbid}})
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end
end

Minitest::Test.include(MusicBrainzStub)
