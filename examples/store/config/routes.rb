Rails.application.routes.draw do
  resources :products, only: %i[index show create update] do
    member do
      post :restock
      get :quote
    end
  end
  resources :orders, only: %i[show create] do
    post :add_item, on: :member
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
